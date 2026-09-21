# Venti (Plan 9)

The ancestor: a 2002 archival server that addresses **blocks**, not files, and
leaves the entire directory tree to its clients — so the tree it builds is a
tree of _pointer blocks_, and filenames live nowhere in it.

|                    |                                                                                                                       |
| ------------------ | --------------------------------------------------------------------------------------------------------------------- |
| **Ecosystem**      | Plan 9 from Bell Labs; `vac`, `vacfs`, `vbackup`, `fossil`, and the Plan 9 file server                                |
| **Level 1**        | **none in the server** — clients build a hash tree of `VtEntry` structures; `vac` layers names on top                 |
| **Level 2**        | **Merkle tree of pointer blocks**, fixed data/pointer block sizes, depth derived from file size                       |
| **Node model**     | three _block types_ — `VtDataType`, `VtDirType`, `VtRootType` — and no file-system node model at all                  |
| **Entry ordering** | **not defined by Venti**; `vac` sorts a `MetaBlock`'s entries byte-wise, with the predicate versioned per block       |
| **Digest**         | SHA-1, 20 raw bytes, called a **score**; the zero-length block's score is the **zero score**                          |
| **Specification**  | [`venti(7)`][venti7] — concepts, block types, zero truncation, and the wire protocol                                  |
| **Documentation**  | [Quinlan & Dorward, _Venti: a new approach to archival storage_, FAST '02][paper]; [`venti(8)`][venti8] (arena/index) |
| **Implementation** | [`include/venti.h`][ventih], [`src/libventi/entry.c`][entryc], [`src/cmd/vac/pack.c`][vacpack] (plan9port)            |

## Overview

### What it solves

Permanent archival storage in which deletion is structurally impossible and
duplicate data costs nothing. The paper opens by naming the policy first and
the mechanism second ([§1 Introduction][paper]):

> Abundant storage suggests that an archival system impose a write-once policy.
> Such a policy prohibits either a user or administrator from deleting or
> modifying data once it is stored. This approach greatly reduces the
> opportunities for accidental or malicious data loss and simplifies the
> system's implementation.

The mechanism that enforces it is content addressing, and Venti states the
identity between the two more sharply than anything else in this survey
([§3 The Venti Archival Server][paper]):

> As blocks are addressed by the fingerprint of their contents, a block cannot
> be modified without changing its address; the behavior is intrinsically
> write-once. This property distinguishes Venti from most other storage
> systems, in which the address of a block and its contents are independent.

### Design philosophy

The server knows about blocks and nothing else. Every structure above a block —
files, directories, whole file systems — is a client convention, and the paper
is explicit that this is a deliberate boundary ([§3][paper]):

> Moreover, the block level interface places few restrictions on the structures
> and format that clients use to store their data. In contrast, traditional
> backup and archival systems require more centralized control.

The naming consequence is the one the rest of this survey inherits ([§3][paper]):

> The hash function can be viewed as generating a universal name space for data
> blocks. Without cooperating or coordinating, multiple clients can share this
> name space and share a Venti server.

And the recursive construction is stated as the _client's_ job, in the sentence
that every later Merkle file-tree traces back to ([§4 Applications][paper]):

> One approach is to pack the fingerprints into additional blocks, called
> pointer blocks, that are also written to the server, a process that can be
> repeated recursively until a single fingerprint is obtained. This fingerprint
> represents the root of a tree of blocks and corresponds to a hierarchical
> hash of the original data.

The paper credits the idea by name in [§8 Related Work][paper]:

> On Venti, blocks are organized into more complex data structures by creating
> hash-trees, an idea originally proposed by Merkle [11] for an efficient
> digital signature scheme.

## How it works

A Venti server exposes four interesting operations over a TCP protocol
(`VtThello`, `VtTread`, `VtTwrite`, `VtTsync`; see the message table in
[`venti(7)`][venti7]). `VtTwrite` carries a `type[1]` and the block `data[]`
and answers with `score[20]`; `VtTread` carries `score[20]`, `type[1]` and a
`count[2]` and answers with the bytes. There is no delete, no rename, no
enumerate, and no path.

`venti(7)` fixes the vocabulary:

> The SHA1 hash that identifies a block is called its _score_. The score of the
> zero-length block is called the _zero score_.

That constant is literally SHA-1 of the empty input —
`da39a3ee5e6b4b0d3255bfef95601890afd80709`, spelled out byte by byte in
[`src/libventi/zeroscore.c`][zeroscorec].

### Building a file out of blocks

[`venti(7)`][venti7] describes the level-2 construction directly:

> The data to be stored is split into fixed-size blocks and written to the
> server, producing a list of scores. The resulting list of scores is split into
> fixed-size pointer blocks (using only an integral number of scores per block)
> and written to the server, producing a smaller list of scores. The process
> continues, eventually ending with the score for the hash tree's top-most
> block.

"An integral number of scores per block" is the whole fanout rule. With the
conventional 8 KiB data and pointer blocks and a 20-byte score, a pointer block
holds `8192 / 20 = 409` scores and the tree reaches:

```text
depth 0        8 KiB          one data block
depth 1      409 ×  8 KiB  ≈  3.2 MiB
depth 2      409² ×  8 KiB ≈  1.3 GiB
depth 3      409³ ×  8 KiB ≈  522 GiB
depth 4      409⁴ ×  8 KiB ≈  208 TiB
```

which is why `VtPointerDepth = 7` and `VtMaxFileSize = (1ULL<<48)-1`
([`venti.h`][ventih]) are comfortable bounds rather than tight ones.

### The block type _is_ the depth

Venti tags every block with a type so a generic tool can walk a structure it
does not understand. The type numbering in [`venti(7)`][venti7] is the
mechanism:

```text
VtDataType     000  data
VtDataType+1   001  scores of VtDataType blocks
VtDataType+2   002  scores of VtDataType+1 blocks
...
VtDirType      010  VtEntry structures
VtDirType+1    011  scores of VtDirType blocks
VtDirType+2    012  scores of VtDirType+1 blocks
...
VtRootType     020  VtRoot structure
```

In [`venti.h`][ventih] that is a base in the high bits and a depth in the low
three:

```c
VtDataType = 0<<3,
VtDirType  = 1<<3,
VtRootType = 2<<3,

VtTypeDepthMask = 7,
VtTypeBaseMask = ~VtTypeDepthMask
```

so a block's type answers "am I data, entries, or a root?" **and** "how many
levels of pointers are below me?" in one byte. No other subject in this survey
puts the tree depth inside the addressed object's tag. The manual also records
that this regularity is retrofitted:

> (For historical reasons, the type numbers used on disk and on the wire are
> different from the above. They do not distinguish `VtDataType+n` blocks from
> `VtDirType+n` blocks.)

`vttodisktype` / `vtfromdisktype` bridge the two.

### `VtEntry`: the closest thing to an inode

A file is summarized by a 40-byte `VtEntry` ([`venti.h`][ventih]):

```c
struct VtEntry
{
    ulong gen;      /* generation number */
    ulong psize;    /* pointer block size */
    ulong dsize;    /* data block size */
    uchar type;
    uchar flags;
    uvlong size;
    uchar score[VtScoreSize];
};
```

[`venti(7)`][venti7]: "Each file stored this way is summarized by a `VtEntry`
structure recording the top-most score, the depth of the tree, the data block
size, and the pointer block size."

There is no name in it. The on-wire packing in
[`src/libventi/entry.c`][entryc] shows how the depth folds into `flags` —

```c
depth = e->type & VtTypeDepthMask;
flags = (e->flags & ~(_VtEntryDir|_VtEntryDepthMask));
flags |= depth << _VtEntryDepthShift;
if(e->type - depth == VtDirType)
    flags |= _VtEntryDir;
```

— laying out `gen[4] psize[2] dsize[2] flags[1] pad[5] size[6] score[20]`, forty
bytes exactly, with `size` a 48-bit field (`U48PUT`). Concatenating `VtEntry`
structures and storing _that_ as a file produces what Venti calls a directory
([`venti(7)`][venti7]):

> One or more `VtEntry` structures can be concatenated and stored as a special
> file called a _directory_. In this manner, arbitrary trees of files can be
> constructed and stored.

A `VtRoot` (300 bytes: `name[128]`, `type[128]`, the score of a directory
block, `blocksize`, and `prev[20]` — the previous root) is the handle a human
passes around. `vac` prints it as an ASCII score with a `vac:` label prefix; the
paper's famous framing is that the whole archive "is always 45 bytes long"
([§4.1 Vac][paper]):

> For a user, it appears that vac compresses any amount of data down to 45
> bytes.

### Storage: an append-only log plus a rebuildable index

Venti separates durability from lookup ([§5 Implementation][paper]):

> The approach we have taken is to separate the storage of data blocks from the
> index used to locate a block. In particular, blocks are stored in an
> append-only log on a RAID array of disk drives. […] A separate index structure
> allows a block to be efficiently located in the log; however, the index can be
> regenerated from the data log if required and thus does not have the same
> reliability constraints as the log itself.

The log is cut into **arenas**, each self-contained and sealed when full ("a
fingerprint is computed for the contents of the entire arena. Sealed arenas are
never modified"), with a directory of block headers at the far end growing
toward the data. The **index** is a disk-resident hash table of buckets keyed by
score, which is also the system's performance ceiling:

> Since the fingerprint of the block contains no internal structure, the
> location of a fingerprint in the index is essentially random.

This split — an immutable content log plus a derived, regenerable index — is
the shape [OSTree][ostree]'s object store, git's packfiles and
[OCI][oci] content stores all arrive at independently.

---

### Dimension 1 — node model

**Absent, and deliberately so.** Venti has no regular file, no directory, no
symlink, no mode bit, no name. It has an 8-bit block type whose meaning "is
left entirely to the client; the server does not interpret the type other that
to use it in conjunction with a fingerprint as the key with which to index a
block" ([§7][paper]). Compare [NAR][nar]'s three-case
[file system object][concepts-fso] or [git][git]'s five modes: Venti is one
level below the question.

The absence is a finding rather than a gap. It means Venti's address space is
strictly _coarser_ than every level-1 scheme here: a Venti score names bytes,
and two different file systems whose blocks happen to coincide share storage
without either knowing. It also means Venti alone cannot answer "are these two
trees equal?" — only "are these two byte sequences equal?".

The node model reappears one layer up, in `vac`'s `VacDir`
([`src/cmd/vac/vac.h`][vach]): `elem` (the path element), `qid`, `uid`, `gid`,
`mid`, `mtime`, `mcount`, `ctime`, `atime`, `mode`. That is the **richest**
metadata set in this survey — richer than [OSTree][ostree]'s uid/gid/mode/xattrs,
and the only one carrying `atime`. Because `vac` is an archiver rather than a
build-input hasher, it has no reason to exclude timestamps, and it does not: two
identical trees vac'd at different times get different root scores while sharing
every data block underneath. The split is instructive — **Venti's identity
excludes all metadata; its client's identity includes essentially all of it**,
and the two compose without either being changed.

### Dimension 2 — canonical form and ordering

Venti has no entry ordering, because it has no entries. It does have exactly one
canonical-form rule, and it is unlike anything else here — **zero truncation**
([`venti(7)`][venti7]):

> To avoid storing the same short data blocks padded with differing numbers of
> zeros, Venti clients working with fixed-size blocks conventionally
> `zero truncate' the blocks before writing them to the server. […] When
truncating pointer blocks (`VtDataType+n`and`VtDirType+n` blocks), trailing
> zero scores are removed instead of trailing zero bytes.

with a consequence that is the neatest fixed point in the catalog:

> Because of the truncation convention, any file consisting entirely of zero
> bytes, no matter what its length, will be represented by the zero score: the
> data blocks contain all zeros and are thus truncated to the empty block, and
> the pointer blocks contain all zero scores and are thus also truncated to the
> empty block, and so on up the hash tree.

A sparse region costs zero bytes and needs no representation for "missing" — the
paper reaches for exactly that when sketching physical backup of only in-use
blocks, "which can easily be achieved on Venti by storing a null value for the
appropriate entry in the pointer tree" ([§4.2][paper]).

Note the word "conventionally". Zero truncation is a rule the _clients_ keep;
the server will happily store an untruncated block under a different score. Venti
is therefore the one subject in this survey whose canonical form is unenforceable
by construction — there is no `fsck` equivalent that could reject a
non-canonical write, because the server cannot tell.

Ordering does exist one layer up, and it is versioned rather than fixed. `vac`
packs directory entries into a `MetaBlock` whose index is sorted by name and
searched with `mbsearch`'s binary search ([`src/cmd/vac/pack.c`][vacpack]).
Which comparison it uses depends on the block's magic:

```c
mb->unbotch = (magic == MetaMagic+1);
...
if(mb->unbotch)
    x = mecmpnew(me, elem);
else
    x = mecmp(me, elem);
```

Both compare name bytes unsigned; they differ only when the search key runs out
first — `mecmp` returns `-1` there, `mecmpnew` returns `1`. The name records the
judgement: the original predicate was wrong for prefix cases, and the fix was
shipped as a new magic number rather than a rewrite, because existing archives
are immutable and must keep reading. This is the same class of hazard as
[git's implicit trailing slash][git-order] — an ordering that cannot be changed
once data exists under it — met with the opposite remedy: git kept the surprise,
`vac` versioned it.

### Dimension 3 — level-1 composition

Merkle, but assembled by the client rather than defined by the format. A
directory is "a special file" holding concatenated `VtEntry` structures, which
means a directory is itself a `VtDataType`-style pointer tree over
`VtDirType` blocks. The recursion bottoms out in a `VtRoot` whose score is the
single fingerprint for the whole archive, exactly as
[git's][git] root tree hash is.

Two divergences from git are worth naming:

- **Names are not in the tree.** `vac` keeps entries and metadata in two
  _parallel_ files — [`venti(7)`][venti7]: "programs do not mix data and
  directory entries in the same file. Instead, they keep two separate files, one
  with directory entries and one with metadata referencing those entries by
  position." So a rename in `vac` rewrites a metadata block, not the entry tree,
  and a name change does not necessarily change the child's identity chain the
  way it does in a git tree.
- **The rationale for the split is generic traversal**: "Keeping this parallel
  representation is a minor annoyance but makes it possible for general programs
  like `venti/copy` […] to traverse the block tree without knowing the specific
  details of any particular program's data." The type byte plus the
  entries/metadata separation is Venti's answer to a problem no other subject
  here has: walking a Merkle structure whose schema you do not know.

### Dimension 4 — level-2 granularity

This is Venti's axis. It is the **only subject in the catalog whose primary tree
is intra-file**, and the only one where the level-2 tree came _first_ and the
level-1 tree was built out of it.

Blocks are fixed-size by convention ("Venti accepts blocks up to 56 kilobytes in
size", [`venti(7)`][venti7]; the paper's prototype caps them at 52 KiB), so
Venti's deduplication is alignment-sensitive, and the paper says so in
[§9 Future Work][paper]:

> To date, the structures we have used for storing data on Venti break files
> into a series of fixed sized blocks. Identical blocks are consolidated on
> Venti, but this consolidation will not occur if the data is shifted within the
> file or an application uses a different block size. This limitation can be
> overcome using an adaptation of Manber's algorithm for finding similarities in
> files [9]. The idea is to break files into variable sized blocks based on the
> identification of anchor or break points, increasing the occurrence of
> duplicate blocks [12].

Reference [12] is Muthitacharoen, Chen & Mazières's LBFS (SOSP 2001) — so
content-defined chunking is named in the 2002 paper as the known fix, and
explicitly scoped as a client change: "Such a strategy can be implemented in
client applications with no change to the Venti server." Everything
[casync][casync] and the [IPFS unixfs][unixfs] chunkers do sits in the hole this
paragraph left open.

Note also what Venti does _not_ do that [Bao][bao] does: the pointer tree is a
lookup structure, not a verification structure with a defined streaming order.
A client fetching block `n` of a file must walk the pointer blocks itself, one
round trip per level, and the paper measures the cost — uncached sequential
reads run at 0.9 MB/s against 14.8 MB/s for the raw array, because "these
sequential reads require a random read of the index" ([§6][paper]).

### Dimension 5 — digest

SHA-1, 160 bits, 20 raw bytes (`VtScoreSize = 20`), with no algorithm agility
anywhere in the protocol: the score field is a fixed 20 bytes in `VtTread`,
`VtRwrite`, `VtEntry` and `VtRoot` alike. The paper's justification is a
birthday bound rather than a security argument ([§3.1][paper]):

> Consider an even larger system that contains an exabyte (10^18 bytes) stored
> as 8 Kbyte blocks (~10^14 blocks). Using the Sha1 hash function, the
> probability of a collision is less than 10^-20.

but it also gives the collision-resistance argument that makes the store safe
against hostile clients — "it prevents a malicious client from intentionally
creating blocks that violate the assumption that each block has a unique
fingerprint" — and it anticipates the migration it never made:

> NIST has already proposed variants of Sha1 that produce 256, 384, and 512 bit
> results [14]. For the immediate future, however, Sha1 is a suitable choice.

Presentation adds a namespace that this survey sees nowhere else: a score may
carry an optional `label:` prefix "typically used to describe the format of the
data" — `vac:`, `ext2:`, `ffs:` ([`venti(7)`][venti7]). A self-describing digest
string, twenty years before multibase.

### Dimension 6 — partial verification

Strong, and at two granularities at once — per block, and per subtree.

Per block, the check is intrinsic and symmetric ([§3][paper]):

> When a block is retrieved, both the client and the server can compute the
> fingerprint of the data and compare it to the requested fingerprint. This
> operation allows the client to avoid errors from undetected data corruption
> and enables the server to identify when error recovery is necessary.

Per subtree, any `VtEntry`'s score verifies its file independently of siblings,
and any pointer block verifies the subtree below it — including _inside_ a
single large file, which of the older subjects only Venti offers. What Venti
lacks relative to [Bao][bao] is a defined proof _encoding_: verification happens
by fetching blocks and hashing them, not by streaming a self-validating byte
sequence, so the cost is a round trip per tree level rather than one pass.

Venti also gets a cache-coherence property free, stated in [§3][paper]:

> Since the contents of a particular block are immutable, the problem of data
> coherency is greatly reduced; a cache or a mirror cannot contain a stale or
> out of date version of a block.

## What the field inherited

Venti predates every other subject in this catalog. Dates below are sourced
where a primary record exists and marked approximate otherwise.

| When              | What                                                                                                                         |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 1980              | Merkle, _Protocols for public-key cryptosystems_ (IEEE S&P, pp. 122–133) — the hash tree Venti cites as its ancestor         |
| 1998              | Stanford Archival Vault — write-once object log, but CRC-named and with "no way to share data between objects" ([§8][paper]) |
| 2000              | SFSRO (Fu, Kaashoek & Mazières, OSDI) — SHA-1 blocks "applied recursively to build up more complex structures" ([§8][paper]) |
| 2001-10           | LBFS (SOSP) — content-defined chunking; Venti cites it as the fix for its own fixed-block limitation                         |
| **2002-01-28/30** | **Venti published at FAST '02**, Monterey CA (pp. 89–102); the HTML proceedings copy is dated "Last changed: 27 Dec. 2001"   |
| 2005-04-07        | Git's first commit — blobs and trees, SHA-1, Merkle DAG, with names in the tree                                              |
| 2011-10-09        | OSTree begins — git's model plus uid/gid/mode/xattrs                                                                         |
| 2020              | BLAKE3 / [Bao][bao] — the intra-file tree Venti built by hand, made intrinsic to the hash function                           |

What later systems took:

- **Content address as write protection.** Venti's "intrinsically write-once"
  framing is the argument every immutable store since has reused, including
  [Nix][nar]'s store and [OCI][oci]'s content-addressable blobs.
- **A recursive pointer tree summarized by one fingerprint.** The `VtRoot` score
  is the direct ancestor of git's root-tree hash, the [NAR][nar] hash, the
  [OSTree][ostree] commit checksum, and IPFS's root CID.
- **Immutable log + rebuildable index.** Reappears as git's packfiles plus
  `.idx`, OSTree's objects plus refs, and every OCI registry's blob store plus
  manifest index.
- **Deduplication as a storage property, not a client obligation.** "Even
  duplicate data from different applications and machines can be eliminated"
  ([§3][paper]).

What later systems diverged on:

- **Names went into the tree.** Git, [REAPI][reapi], [OSTree][ostree] and
  [NAR][nar] all make the directory entry — name, mode, child digest — the
  hashed unit. Venti keeps names in a parallel metadata file and hashes only
  blocks, so it has no entry-ordering question at all. Every one of the four
  orderings this catalog found is a problem Venti does not have, purchased at
  the price of not being able to compare trees.
- **Metadata policy inverted.** Venti excludes _all_ metadata from identity by
  having none; its client `vac` includes _more_ than anyone since, `atime`
  included. The later consensus — exclude timestamps, keep a mode floor — is a
  middle position neither layer occupies.
- **Fixed blocks lost to content-defined chunking.** The `casync`/`bup`/unixfs
  lineage is the execution of Venti's own Future Work paragraph.
- **SHA-1 was replaced.** Venti has no agility seam; the score is 20 bytes
  everywhere, in the protocol and on disk.

## Strengths

- **The purest separation of layers in the catalog**: addressing is
  byte-oriented and policy-free, and every file-system notion is a client
  convention. Two unrelated clients dedupe against each other for free.
- **Depth-in-the-type-byte** makes a Merkle structure traversable by a program
  that does not know its schema — `venti/copy` walks arbitrary client formats.
- **Zero truncation** gives sparse data and all-zero files an identity that
  costs nothing, with a clean fixed point at the zero score.
- **Intra-file partial verification in 2002**, decades before it was reinvented
  as a peer-to-peer requirement.
- **Write-once is enforced by the addressing**, not by permissions — there is no
  delete operation to misuse.
- **The measured case for the model is real**: a decade of daily snapshots from
  two Plan 9 file servers reduced 59.7% (`bootes`) and 76.5% (`emelie`) via
  duplicate elimination, fragment elimination and compression ([Table 2][paper]).

## Weaknesses

- **No level-1 model at all.** Venti cannot express, compare or verify a
  directory tree; it can only store the blocks one is made of.
- **Canonical form is unenforceable.** Zero truncation is a client convention
  the server cannot check, so two encodings of the same file can coexist under
  different scores.
- **Fixed-size blocks** make deduplication alignment-sensitive — acknowledged in
  the paper itself.
- **SHA-1 with no agility**, and the 20-byte score is baked into the wire format,
  the disk format, `VtEntry` and `VtRoot`.
- **The index is the bottleneck**: a score has no internal structure, so every
  write is a random index read, capping throughput at "a few hundred accesses
  per second" per index disk before striping ([§5][paper]).
- **A score is a capability, and a weak one.** "Clients can read any block for
  which they know the fingerprint […] a single root fingerprint enables access
  to an entire file tree and once a fingerprint is known, there is no way to
  restrict access to a particular user" ([§9][paper]).
- **Never deleting is also a liability**: storage consumed by a mistake is
  consumed permanently, by design.

## Key design decisions and trade-offs

| Decision                                             | Rationale                                                                                     | Trade-off                                                                                     |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Address blocks, not files                            | One universal namespace shared by uncoordinated clients; dedup across applications and hosts  | No tree identity; every file-system notion must be rebuilt per client, and clients disagree   |
| Write-once, never delete                             | Removes accidental and malicious loss; simplifies caching, mirroring and coherency            | Mistakes are permanent; storage is never reclaimed                                            |
| Pointer blocks with fixed fanout                     | Arbitrary file sizes from one primitive; depth derivable from size, block size and score size | Random access costs one round trip per level; the paper measures 0.9 MB/s uncached sequential |
| Depth encoded in the block type                      | Generic traversal of unknown client formats (`venti/copy`)                                    | Only 3 bits of depth; and the on-disk type numbering had to be bridged to the regular one     |
| Zero truncation as a client convention               | All-zero and sparse data cost nothing; a clean zero-score fixed point                         | The server cannot enforce it, so non-canonical encodings of the same data are storable        |
| Names and metadata in a file parallel to the entries | Generic tools can walk the block tree without understanding the schema                        | Two structures to keep in step; renames and content changes touch different trees             |
| Fixed-size blocks                                    | Simple, fast, and sufficient for block-structured file systems                                | Insertion shifts break dedup; fixed later by content-defined chunking elsewhere               |
| SHA-1, 20 bytes, everywhere                          | Fast in 2002 (60 MB/s on a 700 MHz P3) and collision-bounded for exabyte-scale stores         | No algorithm agility; the size is structural in protocol, disk format, `VtEntry` and `VtRoot` |
| Append-only log + separately stored index            | The log carries the reliability burden alone; the index is regenerable                        | Index lookups are random by construction and are the system's write-throughput ceiling        |

## Sources

- [Sean Quinlan and Sean Dorward, _Venti: a new approach to archival storage_, Proceedings of FAST '02, pp. 89–102][paper] — the primary source for every quotation above marked with a section number
- [`venti(7)`, plan9port][venti7] — scores, block types, the pointer-tree construction, zero truncation, and the wire protocol
- [`venti(8)`, plan9port][venti8] — arena partitions, index buckets, and the cache tiers
- [`include/venti.h`, plan9port][ventih] — `VtScoreSize`, `VtPointerDepth`, `VtMaxFileSize`, the type enumeration, `VtEntry`, `VtRoot`
- [`src/libventi/entry.c`, plan9port][entryc] — `vtentrypack`: the 40-byte layout and the depth/dir flag encoding
- [`src/libventi/zeroscore.c`, plan9port][zeroscorec] — the zero score as literal bytes
- [`src/cmd/vac/vac.h`, plan9port][vach] — `VacDir`, `MetaMagic`, `MetaHeaderSize`
- [`src/cmd/vac/pack.c`, plan9port][vacpack] — `mbsearch`, `mecmp`/`mecmpnew`, `vdpack`, and the `unbotch` magic

> [!NOTE]
> The plan9port tree is a port of the Plan 9 sources rather than the original
> distribution; it is cited here because it is the revision-pinned copy that can
> be verified at a commit. The USENIX HTML proceedings copy of the paper omits
> Figures 1–6 and the collision-probability formula, which appear only as images
> in the original; nothing quoted above depends on them.

<!-- References -->

[paper]: https://www.usenix.org/legacy/publications/library/proceedings/fast02/quinlan/quinlan_html/index.html
[venti7]: https://github.com/9fans/plan9port/blob/b6564bd96ca189c69e28797738dad56f91eb5967/man/man7/venti.7
[venti8]: https://github.com/9fans/plan9port/blob/b6564bd96ca189c69e28797738dad56f91eb5967/man/man8/venti.8
[ventih]: https://github.com/9fans/plan9port/blob/b6564bd96ca189c69e28797738dad56f91eb5967/include/venti.h
[entryc]: https://github.com/9fans/plan9port/blob/b6564bd96ca189c69e28797738dad56f91eb5967/src/libventi/entry.c
[zeroscorec]: https://github.com/9fans/plan9port/blob/b6564bd96ca189c69e28797738dad56f91eb5967/src/libventi/zeroscore.c
[vach]: https://github.com/9fans/plan9port/blob/b6564bd96ca189c69e28797738dad56f91eb5967/src/cmd/vac/vac.h
[vacpack]: https://github.com/9fans/plan9port/blob/b6564bd96ca189c69e28797738dad56f91eb5967/src/cmd/vac/pack.c
[concepts-fso]: ./concepts.md#file-system-object-fso
[nar]: ./nar.md
[git]: ./git-objects.md
[git-order]: ./git-objects.md#dimension-2--canonical-form-and-ordering
[ostree]: ./ostree.md
[reapi]: ./reapi.md
[bao]: ./bao-blake3.md
[casync]: ./casync.md
[unixfs]: ./ipfs-unixfs.md
[oci]: ./oci-layers.md
