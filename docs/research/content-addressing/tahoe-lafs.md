# Tahoe-LAFS capabilities

The only subject here whose address is a **secret**: a capability from which
both the decryption key and the verification root are derived, so the servers
holding the bytes can store and serve them without ever being able to read
them.

|                    |                                                                                                                                                                  |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Ecosystem**      | Tahoe-LAFS ("Least-Authority File Store"), a decentralized storage grid                                                                                          |
| **Level 1**        | a directed graph of **mutable** dirnodes holding child capabilities — _not_ a Merkle DAG in the general case                                                     |
| **Level 2**        | encrypt → segment → erasure-code, with **three** Merkle structures rooted in a URI Extension Block                                                               |
| **Node model**     | almost empty: a leaf carries "no metadata other than the length in bytes"; metadata lives on the **edge**                                                        |
| **Entry ordering** | **none, and none is possible** — a dirnode's identity is a keypair, not a hash of its contents                                                                   |
| **Digest**         | a printable capability: `URI:CHK:(key):(UEB-hash):(k):(N):(size)`; all hashes SHA-256d under netstring-wrapped tags                                              |
| **Documentation**  | [`docs/architecture.rst`][arch], [`docs/specifications/`][file-enc] (`file-encoding`, `uri`, `URI-extension`, `dirnodes`), [`docs/convergence-secret.rst`][conv] |

> [!NOTE]
> This page covers only what bears on content addressing: how bytes become a
> capability, and what that capability lets each party check. Server selection,
> the `servers-of-happiness` upload health check, leases and garbage collection,
> and the mutable-file two-phase update protocol are out of scope; all are
> covered in [`architecture.rst`][arch] and [`dirnodes.rst`][dirnodes].

## Overview

### What it solves

Storing a file on machines you do not trust, such that they can still
deduplicate it, still verify it, still repair it — and still cannot read it.
Every other subject in this survey assumes the store can see the bytes;
[git][git], [OSTree][ostree] and [REAPI][reapi] hash plaintext, and even
[Bao][bao]'s untrusted-provider threat model is about a peer _lying_ about
bytes it can perfectly well read. Tahoe's design goal is stated as three
attacks the grid must not permit ([`architecture.rst`][arch]):

> 1. violate confidentiality: the attacker gets to view data to which you have
>    not granted them access
> 2. violate integrity: the attacker convinces you that the wrong data is
>    actually the data you were intending to retrieve
> 3. violate unforgeability: the attacker gets to modify a mutable file or
>    directory (either the pathnames or the file contents) to which you have
>    not given them write permission

Denial of service is explicitly conceded; confidentiality, integrity and
unforgeability are not.

### Design philosophy

The address _is_ the authority. A capability carries the secrets needed to do
exactly one thing, and weaker capabilities are derived from stronger ones by
one-way functions, so delegation is a string copy
([`architecture.rst`][arch]):

> The capability provides both "location" and "identification": you can use it
> to retrieve a set of bytes, and then you can use it to validate ("identify")
> that these potential bytes are indeed the ones that you were looking for.

and, on the hierarchy:

> Knowing the read-capability of a file is equivalent to the ability to read
> the corresponding data. The capability to validate the correctness of a file
> is strictly weaker than the read-capability (possession of read-capability
> automatically grants you possession of validate-capability, but not vice
> versa). These capabilities may be expressly delegated (irrevocably) by simply
> transferring the relevant secrets.

Content addressing, in this frame, is an _optional_ property of one capability
type: an immutable file's cap may be derived from its bytes, or from a random
key. [`uri.rst`][uri] is unusually blunt about the naming having outlived the
design:

> Historical note: The name "CHK" is somewhat inaccurate and continues to be
> used for historical reasons. "Content Hash Key" means that the encryption key
> is derived by hashing the contents, which gives the useful property that
> encoding the same file twice will result in the same URI. However, this is an
> optional step [...] The `URI:CHK:` prefix really indicates that an immutable
> file is in use, without saying anything about how the key was derived.

## How it works

### The capability zoo

Capabilities are printable ASCII strings with a type prefix, defined
authoritatively by [`src/allmydata/uri.py`][uri-py] and described in
[`uri.rst`][uri]:

| Cap                 | Names                        | Contents                                          |
| ------------------- | ---------------------------- | ------------------------------------------------- |
| `URI:CHK:`          | an immutable file (read-cap) | read key, UEB hash, `k`, `N`, size                |
| `URI:CHK-Verifier:` | the same file, verify only   | **storage index**, UEB hash, `k`, `N`, size       |
| `URI:LIT:`          | a file of at most 55 bytes   | the file's bytes, base32 — no grid storage at all |
| `URI:SSK:`          | a mutable file (write-cap)   | write key, fingerprint of the RSA public key      |
| `URI:SSK-RO:`       | the same slot, read-only     | read key, same fingerprint                        |
| `URI:SSK-Verifier:` | the same slot, verify only   | storage index, same fingerprint                   |
| `URI:DIR2:`         | a directory (write-cap)      | an `SSK` write-cap, reinterpreted                 |
| `URI:DIR2-RO:`      | a directory, read-only       | an `SSK-RO` read-cap, reinterpreted               |
| `URI:DIR2-CHK:`     | an **immutable** directory   | a `CHK` read-cap, reinterpreted                   |

The derivations are the design. For an immutable file,
`CHKFileURI.get_verify_cap()` constructs the verifier from the same UEB hash
and parameters but substitutes the **storage index** for the read key
([`uri.py`][uri-py]) — and the storage index is itself a one-way function of
that key ([`hashutil.py`][hashutil]):

```python
STORAGE_INDEX_TAG = b"allmydata_immutable_key_to_storage_index_v1"

def storage_index_hash(key):
    return tagged_hash(STORAGE_INDEX_TAG, key, 16)
```

So read-cap → verify-cap is a truncated tagged hash, and there is no path back.
The mutable side has the same shape one level up: the read key is "derived by
hashing the writekey, which allows the holder of a write-cap to produce a
read-cap, but not the other way around" ([`uri.rst`][uri]).

### Encoding an immutable file

One pass to derive the key, one to encrypt, segment and erasure-code
([`file-encoding.rst`][file-enc]):

```text
plaintext
  → AES-CTR key  (convergent: a tagged SHA-256d over params + secret + bytes;
                  or simply random, which disables convergence)
  → ciphertext   (also hashed flat, and into a ciphertext Merkle tree)
  → segments     (128 KiB default; the last is short)
  → per segment: erasure-code into N blocks, one block per server
  → a "share"    = one server's block from every segment
                   + that share's block hash tree
                   + its chain from the share hash tree
```

A hash of the key becomes the **storage index**, which both selects servers and
indexes shares on them. The grid is therefore a map from storage index to
ciphertext, and [`file-encoding.rst`][file-enc] states the consequence in one
line:

> Anybody who knows a Storage Index can retrieve the associated ciphertext:
> ciphertexts are not secret.

### Convergent encryption, and its price

The convergent key is a tagged SHA-256d hash whose tag embeds the convergence
secret _and_ the encoding parameters ([`hashutil.py`][hashutil]):

```python
CONVERGENT_ENCRYPTION_TAG = b"allmydata_immutable_content_to_key_with_added_secret_v1+"

param_tag = netstring(b"%d,%d,%d" % (k, n, segsize))
tag = CONVERGENT_ENCRYPTION_TAG + netstring(convergence) + param_tag
```

`convergence_hasher` then truncates to `KEYLEN = 16` bytes. Two properties
follow that no plaintext-hashing scheme has. First, **`k`, `N` and the segment
size are inside the identity**: "The encoding parameters (k, N, and the segment
size) are included in the hash to make sure that two different encodings of the
same file will get different keys" ([`file-encoding.rst`][file-enc]). Second,
the convergence secret defines a **deduplication domain** — the same bytes
uploaded by two clients converge only if the clients share the secret, and
[`convergence-secret.rst`][conv] frames changing it exactly that way:
"Changing the convergence secret that a storage client uses for uploads can be
though of as moving the client to a new 'deduplication domain'."

The secret exists because deterministic derivation from plaintext is a
confirmation oracle. Both attacks are named in the documentation
([`convergence-secret.rst`][conv]):

> The first one is called the "Confirmation-of-a-File Attack". Someone who
> knows the convergence secret that you used when you uploaded a file, and who
> has a copy of that file themselves, can check whether you have a copy of that
> file.

> The second attack is more subtle. It is called the
> "Learn-the-Remaining-Information Attack". [...] Someone who knows your
> convergence secret can generate a file with all of the boilerplate text [...]
> Then they can try a "brute force search" to find your account number and your
> balance.

The second is the sharper one, and it is not usually stated in discussions of
deduplication: convergence turns a low-entropy _field_ inside an otherwise
confidential document into a brute-forceable one, because the attacker can
confirm each guess by recomputing the cap. The per-node random secret is the
entire mitigation, and the price it charges is the feature: **cross-client
dedup and confidentiality against a guessing attacker are the same dial**.
[`architecture.rst`][arch] records the residual leak even with a secret in
place — "the file size and (when convergence is being used) a keyed hash of the
plaintext are not protected."

### Dimension 1 — node model

Nearly empty, and deliberately so. From [`architecture.rst`][arch]:

> The leaf nodes contain only the data -- they contain no metadata other than
> the length in bytes. The edges leading to leaf nodes have metadata attached
> to them about the file they point to. Therefore, the same file may be
> associated with different metadata if it is referred to through different
> edges.

That is a different placement from every other subject. [git][git] also keeps
the mode in the parent entry rather than the blob, but the mode is still part
of the tree object's hashed bytes, so it is part of the parent's identity. In
Tahoe, a dirnode's identity is a keypair (below), so edge metadata is not part
of _anybody's_ identity — it is mutable annotation, carried as "a JSON-encoded
dictionary of type,value metadata pairs" in the child's fourth netstring
([`dirnodes.rst`][dirnodes]).

There is no executable bit, no symlink, no mode, no uid or gid. What Tahoe has
instead of a node model is a **capability-type taxonomy**: `CHK` versus `LIT`
versus `SSK`/`MDMF` versus `DIR2`, which encodes mutability and access level
rather than anything the OS would restore. A scheme can be rich at the
authority axis and empty at the file system axis — see the
[FSO discussion in concepts][concepts-fso] for the axis this one declines.

### Dimension 2 — canonical form and ordering

**Does not exist for directories, and could not.** A dirnode is the plaintext
of a mutable file, "a serialized list of netstrings, one per child. Each child
is a list of four netstrings: (name, rocap, rwcap, metadata)"
([`dirnodes.rst`][dirnodes]). No sort order is specified, because nothing hashes
this list into an identity: the directory's cap is
`URI:DIR2:(writekey):(fingerprint)`, fixed at creation and unchanged by every subsequent edit.

The format is in fact _actively_ non-canonical. Each child's `rwcap` is stored
as IV + ciphertext + MAC, where "The IV is a 16-byte random value"
([`dirnodes.rst`][dirnodes]) — so re-serializing the same directory produces
different bytes every time, on purpose. That randomness is load-bearing for a
different property (each child's encryption is independently keyed), and it is
free precisely because identity does not depend on the bytes.

The one canonical form Tahoe does define is over the **URI Extension Block**, a
small metadata dictionary whose hash lands in the cap
([`URI-extension.rst`][ueb]):

```text
assert that all keys match ^[a-zA-z_\-]+$
sort all the keys lexicographically
for k in keys:
 write("%s:" % k)
 write(netstring(data[k]))
```

Lexicographic key order plus netstring-delimited values — the same two
ingredients every other subject uses, applied to a parameter dictionary rather
than to a directory. The [four orderings the survey found][rec-ordering] are
orderings of _names in a tree_; Tahoe adds no fifth, because it never sorts
names at all.

### Dimension 3 — level-1 composition

A directed **graph**, not a DAG and not a Merkle structure: "The file store
layer is a graph of directories. Each directory contains a table of named
children. These children are either other directories or files. All children
are referenced by their capability" ([`architecture.rst`][arch]). Since "Any
capability that you receive can be linked in to any directory that you can
modify", cycles are constructible.

The consequence worth stating plainly: **a child's change does not propagate to
its parent's name**. Edit a file, and the containing dirnode's write-cap is
what it always was — the pointer inside it changed, the pointer to it did not.
That is the exact inverse of [git's][git] `O(depth)` ancestor rewrite, and it
buys the property git gives up: stable names for a mutable tree, which is what
makes a shared directory shareable once rather than re-shared per revision.

Tahoe does have a Merkle corner. `URI:DIR2-CHK:` wraps a `CHK` read-cap, so an
immutable directory's cap _is_ a function of its serialized children, and
nesting them yields the familiar hash tree. It is a special case bolted onto a
mutable spine, not the spine itself.

What replaces Merkle propagation as the level-1 invariant is **transitive
read-only access**, enforced by encryption rather than by structure. Each child
row carries both an `rocap` and an `rwcap`, and the `rwcap` column is encrypted
under the parent's writekey ([`dirnodes.rst`][dirnodes]):

> Since other users who have read-only access to 'foo' will be unable to
> decrypt its rwcap slot, this limits those users to read-only access to 'bar'
> as well, thus providing the transitive readonlyness that we desire.

So the capability hierarchy — write ⊃ read ⊃ verify — is preserved downward
through an arbitrary subtree by one AES key, without the parent knowing
anything about the shape below it.

### Dimension 4 — level-2 granularity

The richest in the survey, and structured differently from
[Bao/BLAKE3][bao] in a way that matters.

Bao's tree is over the file's own bytes at a geometry fixed by length: a leaf
_is_ a substring of the file, and the root _is_ the address. Tahoe's
verification trees are over **post-encryption, post-erasure-coding artifacts**,
and there are three of them ([`file-encoding.rst`][file-enc]):

| Tree                   | Leaves                               | Root goes to                         |
| ---------------------- | ------------------------------------ | ------------------------------------ |
| block hash tree        | the blocks of **one share**          | that share's "block root hash"       |
| share hash tree        | the block root hashes, one per share | `share_root_hash`, stored in the UEB |
| ciphertext Merkle tree | segments of the ciphertext           | `crypttext_root_hash`, in the UEB    |

The block and share trees form a single two-level structure whose leaves are
encoded blocks — so a leaf a server proves is not a substring of the file at
all, and cannot be checked against the plaintext until `k` shares have been
decoded. The ciphertext tree exists for exactly that gap: it is what "verifies
the correctness of the erasure decoding step, and can be used by a 'verifier'
process to make sure the file is intact without requiring the decryption key"
([`file-encoding.rst`][file-enc]).

The UEB is then the join point, and the cap holds only its hash: "The UEB
contains all the non-secret values that could be put in the URI, but would have
made the URI too big. So instead, the UEB is stored with the share, and the
hash of the UEB is put in the URI" ([`file-encoding.rst`][file-enc]). The UEB
is required to be constant-size for all files, which is why the hash trees live
beside it rather than in it ([`URI-extension.rst`][ueb]).

Segment size is a tunable (128 KiB by default) with the same trade-off
[Bao][bao] resolves at 16 KiB: smaller segments improve "alacrity" — "the
number of bytes we have to receive before we can deliver validated plaintext to
the user" — at the cost of more Merkle hashes to carry.

> [!NOTE]
> [`file-encoding.rst`][file-enc] describes the block hash tree as "a total of
> two SHA-1 hashes per block", which contradicts its own `Hashes` section
> ("All hashes use SHA-256d") and the implementation — `block_hash` is
> `tagged_hash(BLOCK_TAG, data)` over the SHA-256d hasher in
> [`hashutil.py`][hashutil]. Read the SHA-1 mention as stale prose.

### Dimension 5 — digest

Not a digest: a tuple, and one field of it is secret.

```text
URI:CHK:auxet66ynq55naiy2ay7cgrshm:6rudoctmbxsmbg7gwtjlimd6umtwrrsxkjzthuldsmo4nnfoc6fa:3:10:1000000
         \__ 16-byte AES read key __/\____ SHA-256 hash of the UEB ______________________/ k  N  size
```

Base32, lower-case, `=` padding stripped ([`uri.rst`][uri]). The storage index
is absent because it is derivable from the key. What the cap pins, then, is
three separable things at once: **a decryption key** (confidentiality), **a
verification root** (integrity, via the UEB hash and the trees it roots), and
**an encoding contract** (`k`, `N`, size — the parameters a downloader needs
before it can ask enough servers in parallel).

Every hash is SHA-256d under a single-purpose tag, wrapped in netstrings
([`file-encoding.rst`][file-enc]):

```text
SI = SHA256d(netstring("allmydata_immutable_key_to_storage_index_v1") + key)
```

The doubling guards length extension; the tag guards leaf/interior confusion in
the Merkle trees; the netstring guards tag/value boundary confusion. That is a
more careful hashing discipline than any other subject in this survey states —
[git's][git] `<type> <size>\0` prefix is the closest analogue and is one
mechanism where Tahoe has three.

Two edge cases are worth recording. `URI:LIT:` inlines files of at most 55
bytes directly into the cap, "which is the point at which the LIT URI is the
same length as a CHK URI would be" ([`uri.rst`][uri]) — the address _is_ the
data, so there is no grid object, no share, and `get_verify_cap()` returns
`None` for its directory form ([`uri.py`][uri-py]). And mutable caps are not
content addresses at all: the fingerprint is a hash of the RSA public key, so
"the data validation is limited to confirming that the data retrieved matches
_some_ data that was uploaded in the past, but not which version of that data"
([`uri.rst`][uri]).

### Dimension 6 — partial verification

Complete, at segment granularity, and with an authority tier nothing else here
has. [`architecture.rst`][arch] gives the motivating case:

> It uses Merkle Trees so that it is possible to verify the correctness of a
> subset of the data without requiring all of the data. For example, this
> allows you to verify the correctness of the first segment of a movie file and
> then begin playing the movie file in your movie viewer before the entire
> movie file has been downloaded.

Mechanically it is the interleave [Bao][bao] also uses: a server sends the
share hash chain (`log2(numshares)` hashes) to validate its block root hash,
then the portion of the block hash tree needed for block _N_, then block _N_,
looping.

The tier that is unique here is **verification without read authority**. The
repairer "does not get the full capability of the file to be maintained: it
merely gets the 'repairer capability' subset, which does not include the
decryption key" ([`architecture.rst`][arch]), and can still download the
ciphertext, check it against `crypttext_root_hash`, regenerate missing shares
and upload them. Repair is a pure function of ciphertext and encoding
parameters; it never touches plaintext. In every other subject, an agent that
can verify an object can also read it.

### What a storage server can and cannot check

Worth stating explicitly, because it is the axis this subject contributes.

A storage server holds, per storage index, a set of shares and the UEB copy
stored alongside each one ("All buckets hold an identical copy",
[`URI-extension.rst`][ueb]). It therefore **can** see the file size, the
encoding parameters, the Merkle roots, and the fact that some client is reading
or writing that index. It **cannot** decrypt anything: the read key is only in
the cap, and the storage index is a one-way image of it. It cannot tell that
two storage indices are the same plaintext uploaded under different convergence
secrets. And it is never given the cap, so it cannot check a share against the
value a client used to name the file — verification is a client-side act, run
by whoever holds a read-cap or a verify-cap.

The confirmation attack is exactly the boundary case: a party who knows both
the convergence secret and a candidate plaintext can recompute the key, hence
the storage index, hence ask any server whether that index exists. That is the
same derivation the uploader ran, used backwards as an oracle — and it is why
the convergence secret is per-node and random by default.

## Strengths

- **Confidentiality and dedup in one primitive** — convergence gives
  content-addressed identity over data the store cannot read.
- **A real capability hierarchy**: write ⊃ read ⊃ verify, with each derivation
  one-way, so delegation is copying a string and attenuation needs no server
  cooperation.
- **Repair without read authority** — a strictly weaker cap suffices to check
  and regenerate shares, which no plaintext-hashing scheme can express.
- **Segment-granular partial verification**, with the streaming-playback use
  case designed in.
- **Availability is part of identity**: `k`, `N` and size travel in the cap, so
  a downloader can parallelize its first round of queries.
- **Careful hash discipline** — SHA-256d, single-purpose tags, netstring
  framing, each guarding a named attack.

## Weaknesses

- **Convergence is a confirmation oracle**, and worse, a
  learn-the-remaining-information oracle against low-entropy fields inside
  otherwise confidential documents. The mitigation (a per-node secret) costs
  cross-client dedup outright.
- **No level-1 content addressing in the general case** — a directory's
  identity is a keypair, so there is no subtree digest, no cheap tree
  comparison, and no way to name "this tree as of now" without an immutable
  `DIR2-CHK` snapshot.
- **The file system object model is nearly empty**: no modes, no symlinks, no
  permissions. Tahoe is not trying to round-trip a POSIX tree.
- **Caps are secrets**, so they cannot be logged, put in a cache key, or
  published — the inverse of every other subject's digest, which is safe to
  print anywhere.
- **Identity depends on encoding policy.** Change `k`, `N` or the segment size
  and the same bytes get a different cap; re-encoding is re-uploading.
- **Two passes over the plaintext** for a convergent upload, since the key
  cannot be chosen before the file has been read.
- **Revocation is impossible**: delegation is "irrevocably" by transferring
  secrets ([`architecture.rst`][arch]).
- **`URI-extension.rst` still lists `plaintext_hash` / `plaintext_root_hash`**
  among the UEB keys, a historical leak vector for the guessing attacks above;
  the specification document has not been pruned.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                             | Trade-off                                                                                      |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| The address is a capability, not a hash of the plaintext | One value carries location, decryption and verification; delegation is a string copy  | The address is secret — it cannot be logged, published, or used as a cache key                 |
| Derive the key from the content (convergence)            | Two uploads of the same file cost one copy on the grid                                | A confirmation-of-a-file oracle, and a brute-force oracle over low-entropy fields              |
| Mix a per-node random secret into the convergence hash   | Closes both oracles to everyone outside the node                                      | Dedup only inside a "deduplication domain"; cross-client dedup requires sharing the secret     |
| Put `k`, `N` and segment size inside the key derivation  | "two different encodings of the same file will get different keys"                    | Identity tracks storage policy, so re-tuning the grid rewrites every cap                       |
| Erasure-code into `k`-of-`N` shares                      | Survives loss of most servers; download pulls from many peers at once                 | No stored artifact hashes to anything in the cap; ~3.3x upload expansion at the defaults       |
| Hash the **encoded blocks**, not just the plaintext      | A server can be caught lying about its share before any decode                        | A second (ciphertext) tree is needed to catch a bad decode, and both roots must be carried     |
| Put the roots in a UEB and only its hash in the cap      | The cap stays short and constant-size regardless of file size or share count          | An extra fetch-and-validate round before any decoding can begin                                |
| Directories are mutable files holding child caps         | A shared directory keeps one name across every edit                                   | No Merkle propagation: no subtree digest, no cheap tree diff, cycles are constructible         |
| Encrypt the `rwcap` column under the parent's writekey   | Read-only access is transitive through an arbitrary subtree, enforced by cryptography | Each child needs its own random IV, so dirnode bytes are deliberately non-canonical and larger |
| Inline files of at most 55 bytes into the cap (`LIT`)    | Below that size the cap is no smaller than the data                                   | A whole second identity shape with no grid object and no verify-cap                            |

## Sources

All citations pin `tahoe-lafs/tahoe-lafs` at
`f002fd0d27d9a3da5c0da162b10725838353bd63`.

- [`docs/architecture.rst`][arch] — the three layers, the capability hierarchy, the security goals, the repairer capability
- [`docs/specifications/file-encoding.rst`][file-enc] — convergent vs random key, segmentation, the block/share/ciphertext trees, the tagged-hash discipline
- [`docs/specifications/uri.rst`][uri] — the cap grammar, the CHK naming note, write→read derivation for mutable files
- [`docs/specifications/URI-extension.rst`][ueb] — the UEB key set and its canonical serialization
- [`docs/specifications/dirnodes.rst`][dirnodes] — the four-netstring child row, the encrypted `rwcap` column, transitive read-only access
- [`docs/convergence-secret.rst`][conv] — the confirmation-of-a-file and learn-the-remaining-information attacks, and deduplication domains
- [`src/allmydata/uri.py`][uri-py] — the authoritative cap classes and the `get_verify_cap` / `get_readonly` derivations
- [`src/allmydata/util/hashutil.py`][hashutil] — `tagged_hash`, `storage_index_hash`, and the convergence tag construction

<!-- References -->

[concepts-fso]: ./concepts.md#file-system-object-fso
[git]: ./git-objects.md
[ostree]: ./ostree.md
[reapi]: ./reapi.md
[bao]: ./bao-blake3.md
[rec-ordering]: ./recommendations.md#axis-2--entry-ordering
[arch]: https://github.com/tahoe-lafs/tahoe-lafs/blob/f002fd0d27d9a3da5c0da162b10725838353bd63/docs/architecture.rst
[file-enc]: https://github.com/tahoe-lafs/tahoe-lafs/blob/f002fd0d27d9a3da5c0da162b10725838353bd63/docs/specifications/file-encoding.rst
[uri]: https://github.com/tahoe-lafs/tahoe-lafs/blob/f002fd0d27d9a3da5c0da162b10725838353bd63/docs/specifications/uri.rst
[ueb]: https://github.com/tahoe-lafs/tahoe-lafs/blob/f002fd0d27d9a3da5c0da162b10725838353bd63/docs/specifications/URI-extension.rst
[dirnodes]: https://github.com/tahoe-lafs/tahoe-lafs/blob/f002fd0d27d9a3da5c0da162b10725838353bd63/docs/specifications/dirnodes.rst
[conv]: https://github.com/tahoe-lafs/tahoe-lafs/blob/f002fd0d27d9a3da5c0da162b10725838353bd63/docs/convergence-secret.rst
[uri-py]: https://github.com/tahoe-lafs/tahoe-lafs/blob/f002fd0d27d9a3da5c0da162b10725838353bd63/src/allmydata/uri.py
[hashutil]: https://github.com/tahoe-lafs/tahoe-lafs/blob/f002fd0d27d9a3da5c0da162b10725838353bd63/src/allmydata/util/hashutil.py
