# bup & git-annex

Two answers to "git is bad at big files": bup puts a **content-defined chunk
tree inside git's own object model**, proving the two levels compose; git-annex
takes the bytes **out of the object graph entirely**, proving what that costs.

|                    |                                                                                                                           |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| **Ecosystem**      | Backup (bup) and large-file management (git-annex); both are literally git repositories                                   |
| **Level 1**        | **Git trees, unmodified** — plus bup's optional hashsplit _tree splitting_ for huge directories                           |
| **Level 2**        | bup: content-defined chunks, average 8 KiB, stored as **git blobs**. git-annex: **none** — content is not in git at all   |
| **Node model**     | git's five modes, with bup's out-of-band `.bupm` metadata stream; git-annex adds nothing (a symlink or pointer file)      |
| **Entry ordering** | git's — byte-wise with the [implicit trailing `/`][git-order]; bup names chunk-tree entries by zero-padded **hex offset** |
| **Digest**         | git's SHA-1 (bup); a per-backend key string such as `SHA256E-s31390--<hex>.mp3` (git-annex)                               |
| **Documentation**  | bup [`DESIGN.md`][design]; git-annex [internals][ga-internals], [key format][ga-key], [backends][ga-backends]             |

## Overview

### What it solves

Git stores a file as one whole blob and a directory as one whole tree object.
Both assumptions break on a backup workload. bup's [`DESIGN.md`][design] names
the three failures precisely:

> git can't handle huge files; b) git is too slow when you give it too many
> files; and c) git doesn't store detailed filesystem metadata.

and diagnoses the first as a consequence of git's _delta_ strategy rather than
its _addressing_ strategy:

> The primary reason git can't handle huge files is that it runs them through
> xdelta, which generally means it tries to load the entire contents of a file
> into memory at once. […] Unfortunately, xdelta works great for small files
> and gets amazingly slow and memory-hungry for large files.

git-annex answers the same question by refusing it. From
[how it works][ga-how]:

> Git's man page calls it "a stupid content tracker". With git-annex, git is
> instead "a stupid filename and metadata tracker". The contents of annexed
> files are not stored in git, only the names of the files and some other
> metadata remain there.

### Design philosophy

bup's claim is that git's level-1 model is _already right_ and only level 2
needs replacing. Its replacement is content-defined chunking, described in
[`DESIGN.md`][design] in one paragraph that is the clearest statement of CDC in
this survey:

> We read through the file one byte at a time, calculating a rolling checksum
> of the last 64 bytes. […] Basically, it converts the last 64 bytes read into
> a 32-bit integer. What we then do is take the lowest 13 bits of the rollsum,
> and if they're all 1's, we consider that to be the end of a chunk. This
> happens on average once every 2^13 = 8192 bytes, so the average chunk size
> is 8192 bytes.

and whose payoff is stated as the insertion-resilience property that
[casync][casync] also claims:

> But with hashsplitting, no matter how much data you add, modify, or remove in
> the middle of the file, all the chunks _before_ and _after_ the affected
> chunk are absolutely the same. […] Like magic, the hashsplit chunking
> algorithm will chunk your file the same way every time, even without knowing
> how it had chunked it previously.

The document is also unusually honest about how its constants were chosen —
"(Why 64? No reason. Literally. We picked it out of the air.)" and "(Why 13
bits? Well, we picked the number at random and… eugh.)" — which is itself
evidence for a catalog finding: the _shape_ of the scheme is load-bearing, the
tuning constants are not.

git-annex's philosophy is the complementary one — the key is a string, not a
graph node, and the backend that computes it is a per-file choice
([backends][ga-backends]):

> The "backend" in git-annex specifies how a key is generated from a file's
> content and/or filesystem metadata. Most backends are different kinds of
> hashes. A single repository can use different backends for different files.
> The key includes the backend that is used for that key.

## How it works

### bup: hashsplitting

The rolling checksum is `rollsum`, adopted from librsync and defined in
[`bupsplit.h`][bupsplit-h]. It is an Adler-style pair over a **fixed** 64-byte
window (`BUP_WINDOWBITS` is `6`), with a `ROLLSUM_CHAR_OFFSET` of `31`:

```c
#define BUP_WINDOWBITS (6)
#define BUP_WINDOWSIZE (1<<BUP_WINDOWBITS)
#define ROLLSUM_CHAR_OFFSET 31

static inline void rollsum_add(Rollsum *r, uint8_t drop, uint8_t add)
{
    r->s1 += add - drop;
    r->s2 += r->s1 - (BUP_WINDOWSIZE * (drop + ROLLSUM_CHAR_OFFSET));
}

static inline uint32_t rollsum_digest(Rollsum *r)
{
    return (r->s1 << 16) | (r->s2 & 0xffff);
}
```

`rollsum` replaced an earlier algorithm the document calls "stupidsum", named
after its own quality: it "was thoroughly discredited in that article for being
very stupid. But, as so often happens, Avery couldn't remember any better
algorithms from the article." The replacement is documented as "essentially the
same as what rsync does, except we use a fixed window size" — the fixed window
being the one deliberate divergence, and the reason bup's boundaries are
reproducible without carrying rsync's window-size formula.

The boundary test lives in [`_hashsplit.c`][hashsplit-c], and tests the two
16-bit halves separately so the 32-bit digest never has to be materialised on
the hot path:

```c
const uint16_t s2_mask = (1 << nbits) - 1;
const uint16_t s1_mask = (nbits <= 16) ? 0 : (1 << (nbits - 16)) - 1;
// ...
if ((r->s2 & s2_mask) == s2_mask && (r->s1 & s1_mask) == s1_mask) {
```

`nbits` defaults to `BUP_BLOBBITS = 13` ([`hashsplit.py`][hashsplit-py]), and
`bup.split.files` may raise it to at most `21` via a `legacy:NN` setting — a
_versioned_ chunking policy, since changing it changes every digest. The
maximum blob is `1 << (bits + 2)`, i.e. four times the average, so a stretch of
data with no separator still terminates.

### bup: fanout

A 200 GB file becomes roughly 24 million chunks. The list of their SHA-1s is
itself a large, almost-but-not-quite-stable object — "20/8192 = 0.25% of the
file length. For a 200GB file, that's 488 megs of just sequence data." bup
declines to hashsplit that list, because the list must remain a real git tree:

> We could have, in fact, but it wouldn't have been very "git-like", since we'd
> like to store the list as a git 'tree' object in order to make sure git's
> refcounting and reachability analysis doesn't get confused. Never mind the
> fact that we want you to be able to 'git checkout' your data without any
> special tools.

Instead it reuses the _same_ rolling checksum at a higher bit position — the
mechanism named **fanout**:

> Instead of checking just the last 13 bits of the checksum, we use additional
> checksum bits to produce additional splits. […] let's say we use a 4-bit
> fanout. That means we'll break a series of chunks into its own tree object
> whenever the next 4 bits of the rolling checksum are 1, in addition to the 13
> lowest ones. Since the 13 lowest bits already have to be 1, the boundary of a
> group of chunks is necessarily also always the boundary of a particular
> chunk.

`HashSplitter_roll` therefore returns, alongside the split offset, a count of
contiguous one bits above the mask; `hashsplit.py` divides it by `fanbits` to
get a tree **level**, and `_squish` folds the accumulated stacks into git tree
objects at that level. `fanout = 16` gives `fanbits = 4`, so a group closes
with probability `1/16` per chunk: about **16 chunks ≈ 128 KiB per leaf tree**,
`256` chunks ≈ 2 MiB per second-level tree, and so on. `MAX_PER_TREE = 256`
forces a squish regardless, bounding any one tree object.

One documented wart: the bit immediately above the 13 is skipped.

> Note that (most likely due to an implementation bug), the next higher bit
> after the 13 bits (marked 'x'):
>
> ```text
>   ...... '..x1'1111'1111'1111
> ```
>
> is actually ignored (so the fanout starts just to the left of the x).

The code preserves the bug deliberately, with a comment pointing back at the
design document — a frozen quirk, exactly like git's implicit slash.

### bup: what the chunk tree looks like

Entries in a chunk tree are not named after content. `_make_shalist` names each
one by its **byte offset in the reconstructed file**, in lowercase hex,
zero-padded to the width of the total size:

```python
vlen = len(b'%x' % total)
shalist.append((mode, b'%0*x' % (vlen, ofs), sha))
```

Fixed width means git's byte-wise name order _is_ numeric offset order, and a
seek to offset `N` is a descent comparing hex prefixes — which is how `bup
fuse` gets random access. A chunked file is then hidden behind a name
mangling in [`git.py`][git-py]: a regular file stored as a tree is checked in
as `name.bup`, and a genuine file already ending in `.bup` becomes `name.bupl`
to disambiguate.

### bup: tree splitting, and the huge-directory problem

The same machinery is applied a second time, to directories rather than files:

> git doesn't handle frequently changing large directories well either, since
> they're stored in a single tree object using up 28 bytes plus the length of
> the filename for each entry (record). […] Imagine an active Maildir
> containing tens or hundreds of thousands of files.
>
> […] The trees are split in a manner similar to the file hashsplitting
> described above, but with the restriction that splits may only occur between
> (not within) tree entries.

`RecordHashSplitter` in [`_hashsplit.c`][hashsplit-c] is that restricted
splitter: it is fed whole records and returns `(split, bits)`. The resulting
intermediate levels are named by the first filename in each subtree, truncated
to the shortest unique prefix, and suffixed `..DEPTH.bupd`:

```text
dir/.b..1.bupd/{.bupm,aa,...,ii}
dir/j..1.bupd/{jj,...,rr}
dir/s..1.bupd/{ss,...,zz}
```

> At any level, the names contained in a subtree will always be greater than or
> equal to the name of the subtree itself and less than the name of the next
> subtree at that level. This makes it possible to know which split subtree to
> read at every level when looking for a given filename.

This is **the survey's second answer to the huge-directory problem**, and it is
not [IPFS unixfs's][unixfs]. unixfs shards by _hash_ into a HAMT, so a lookup
is a hash-prefix descent and the shard structure is independent of the names;
bup shards by _sorted position_, so a lookup is a B-tree-style ordered descent
and the intermediate names are real prefixes of real filenames. The trade-off
falls out of that choice: HAMT gives uniform shard occupancy and an
order-independent layout; bup's split keeps the directory listable in sorted
order with no extra index, and keeps the result a plain git tree that
`git checkout` can walk, at the cost of an occupancy that follows the name
distribution. Both are `O(log n)` on lookup; only bup's preserves ordering.

Everything git's five modes cannot express — uid, gid, full mode, ACLs,
timestamps — lives beside the tree in a `.bupm` blob, one record sequence per
entry. Its ordering is documented as _not_ matching the tree's, but as
accounting for git's sort rule anyway:

> the `.bupm` ordering does account for the fact that git sorts trees
> (including chunked trees) as if their names ended with "/" (so "fo" sorts
> after "fo." iff fo is a directory).

An independent restatement, in a second codebase, of the
[implicit-slash finding][git-order].

### git-annex: the pointer

git-annex stores, in git, a symlink (locked) or a small **pointer file**
(unlocked) whose target is a _key_. Keys have a documented grammar
([key format][ga-key]):

```text
BACKEND[-sNNNN][-mNNNN][-SNNNN-CNNNN]--NAME
SHA256E-s31390--f50d7ac4c6b9031379986bc362fcefb65f1e52621ce1708d537e740fefc59cc0.mp3
```

The backend name is _inside_ the key — `SHA256E` is SHA-256 plus the file's
extension, `SHA256` without it, and `WORM` is not a hash at all but
"filename, size, and modification time". `-s` is the size; `-m` an mtime used
only by `WORM`; `-S`/`-C` mark a key that is a fixed-size chunk of another key.
Content lives under `.git/annex/objects/aa/bb/<key>/<key>`, and _which
repositories hold it_ is tracked in an orthogonal `git-annex` branch of
append-only, timestamp-per-line logs designed to merge by concatenation.

### Dimension 1 — node model

**bup**: git's five modes, plus a parallel `.bupm` metadata stream carrying
"a common record type (containing the normal stat information), a symlink
target type, a hardlink target type, a POSIX1e ACL type". Where [OSTree][ostree]
folded uid/gid/mode/xattrs _into_ the content hash, bup keeps them in a blob
that the tree merely references — so metadata changes cost one blob rather than
invalidating the file's identity, and a repository with no `.bupm` degrades to
plain git behaviour.

**git-annex**: nothing beyond git's. An annexed file is a symlink or a pointer
file; its mode, owner and times are whatever git records, which is to say the
executable bit and nothing else.

### Dimension 2 — canonical form and ordering

**bup** inherits git's ordering wholesale, including the implicit slash, and it
must: the trees it writes are read by `git checkout`. Inside a chunk tree the
ordering question is answered by construction — fixed-width zero-padded hex
offsets sort byte-wise into numeric order. Inside a _split_ tree, subtree names
are unique prefixes of the first contained filename, so the ordered-descent
invariant quoted above holds under git's comparator.

Canonicity holds only relative to a fixed splitting configuration: `blobbits`,
`fanbits` and `bup.split.trees` all change the object graph for identical
bytes. bup makes that explicit — `configuration()` in
[`hashsplit.py`][hashsplit-py] returns "every option that affects the way data
will be split", and the file-splitting method is spelled `legacy:13` … `legacy:21`,
i.e. a version tag. That is a stronger position than [IPFS's][unixfs], where
import parameters are equally decisive but not named as a unit.

**git-annex** has no canonical form to speak of at level 1 — the tree is an
ordinary git tree of symlinks. At key level the grammar is canonical: "git-annex
always puts the fields in the order shown above when serializing a key."

### Dimension 3 — level-1 composition

**bup**: git's Merkle DAG, unchanged, and that is the entire point. bup adds no
level-1 scheme; it adds objects _inside_ the existing one. The consequence it
advertises is the DAG property applied to chunks:

> the tree itself is pretty stable across file modifications. Any one
> modification will only affect the chunks actually containing the
> modifications, thus only the groups containing those chunks, and so on up the
> tree. Essentially, the number of changed git objects is O(log n) where n is
> the number of chunks.

`O(log n)` _within a file_ — git's `O(depth)` subtree property, recursively
re-derived one level down. This is the catalog's cleanest evidence that level 1
and level 2 are independent: bup swapped level 2 for a chunk tree and level 1
did not notice.

**git-annex**: also git's DAG, but the DAG's leaves are 50-byte symlinks. The
level-1 composition is intact and completely uninformative about the data.

### Dimension 4 — level-2 granularity

**bup**: content-defined, average `2^13 = 8192` bytes, capped at `2^15`, over a
64-byte rolling window — then _recursively grouped_ by higher bits of the same
checksum into a tree whose nodes are git trees. Compare the two neighbours:
[casync][casync] chunks across file boundaries and stores the chunk list in a
purpose-built flat index; [Bao][bao] fixes 1024-byte chunks so tree geometry is
derivable from length alone. bup sits between them — boundaries are
content-defined like casync's, but the resulting structure is a real Merkle
tree like Bao's, and it is made of objects the host system already understands.

**git-annex**: **not applicable, and deliberately so.** A file's content is one
opaque value behind one key; there is no chunk tree, no partial object, nothing
git can address below the whole file. Special-remote `chunk=nnMiB`
([chunking][ga-chunking]) splits content for _transfer_, but those are
fixed-size boundaries chosen per remote, recorded as `-S`/`-C` chunk keys, and
exist "to work around limitations on the size of files on the remote" and to
allow resume — a transport concern, not an identity.

### Dimension 5 — digest

**bup**: SHA-1, because git's. Every chunk is a git blob and every group a git
tree, so `git cat-file` and `git fsck` are independent oracles for a bup
repository. Size is not part of the identity (git's framing already carries a
length prefix), though bup records it in the chunk-tree entry _names_.

**git-annex**: a _string_, not a hash — and the only digest in this survey that
names its own function without a multiformats-style registry. `SHA256E`,
`BLAKE3_256`, `XXH3`, `MD5E`, `WORM`, `URL`, `VURL` are all keys in the same
namespace, and `annex.backend` may be set per glob in `.gitattributes`. Like a
[CID][unixfs] it is self-describing; unlike a CID the encoding is an ASCII
grammar with optional `-s`/`-m`/`-S`/`-C` fields rather than a varint
concatenation, and `WORM` shows the escape hatch a registry-based design cannot
offer: a "digest" that is not a function of the content at all.

### Dimension 6 — partial verification

**bup**: per git object, and therefore _per chunk inside a file_ — the property
git alone lacks. Holding a chunk-tree root, a consumer can fetch and verify the
subtree covering one byte range and ignore the rest, which is what `bup fuse`
does. bup also exploits the DAG's transitive guarantee to skip work entirely:

> if you know a particular tree's sha1 is correct […] you don't have to
> re-verify the validity of all its children; because of the way git trees and
> blobs work, if your repository is valid and you have a tree object, then you
> have all the blobs it points to.

**git-annex**: whole-object only, and only for the checksumming backends. A
`SHA256E` key verifies after the entire file has been retrieved; `WORM` and
`URL` keys cannot be verified at all, which is why `annex.securehashesonly`
exists.

## Strengths

- **bup proves the levels compose.** A content-defined chunk tree was added
  _underneath_ git's tree model with no change to level 1, and the result is
  still a repository `git checkout` can read.
- **Fanout reuses one checksum for two jobs**: the same rolling value that
  picks chunk boundaries also picks group boundaries, so the tree is as stable
  as the chunking, and updates are `O(log n)` objects within a file.
- **Tree splitting answers the huge-directory problem while preserving name
  order** — unlike [HAMT sharding][unixfs], a split directory is still listable
  in sorted order by ordinary descent.
- **Ubiquitous oracle**: `git fsck`, `git cat-file`, `git checkout` all work on
  a bup repository unmodified.
- **git-annex's key is self-describing and per-file negotiable**, so one
  repository can mix SHA-256, BLAKE3 and a non-hash `WORM` key.
- git-annex keeps the git repository genuinely small — clone cost is
  independent of content size.

## Weaknesses

- **bup's canonical form depends on tuning constants** (`blobbits`, `fanbits`,
  `bup.split.trees`), so two bups can disagree about the same bytes; the
  `legacy:NN` spelling manages this but does not remove it.
- **A preserved implementation bug** — the ignored 14th bit — is now part of
  the format.
- **The mangled-name layer leaks**: `.bup`, `.bupl`, `.bupm`, `.bupd` suffixes
  are visible to any plain git tool, so "you can `git checkout` your data" is
  true only modulo demangling and `.bupm` reassembly.
- **Metadata is out-of-band**, so a `.bupm` and its tree can disagree, and
  their orderings already do.
- **git-annex has no level 2 at all**: no dedup below the file, no partial
  fetch, no partial verification.
- **git-annex's content is not in the Merkle graph**, so a commit's digest
  proves nothing about the data it names — the reachability and integrity
  guarantees git gives for free must be rebuilt as `git annex fsck` plus
  location-tracking logs.
- `WORM` and `URL` keys are addressable but unverifiable.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                                               | Trade-off                                                                                                 |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Chunk into **git blobs**, group into **git trees** (bup) | "git's refcounting and reachability analysis" keeps working; `git checkout` still restores data         | Every chunk is a real object to index and pack; 24 million of them for a 200 GB file                      |
| Content-defined boundaries over a fixed 64-byte window   | An insertion shifts at most one boundary, so chunks before and after are unchanged                      | Chunk geometry is not derivable from length, unlike [Bao][bao]                                            |
| Test the lowest 13 bits                                  | 1-in-8192 separator density; average chunk 8 KiB against a 20-byte SHA-1, so sequence overhead is 0.25% | Picked "at random"; sizes are exponentially distributed and skew small; a policy change rewrites every id |
| Cap the blob at `1 << (bits + 2)`                        | Bounds worst-case chunk size on separator-free data                                                     | The cap's boundaries are _not_ content-defined, so a run of incompressible data dedups poorly             |
| **Fanout** from higher bits of the same checksum         | Chunk-group boundaries are automatically chunk boundaries; the tree is as stable as the chunking        | An off-by-one in the bit position became permanent format                                                 |
| Name chunk-tree entries by zero-padded hex offset        | Byte order equals numeric order, so seeking is an ordered descent; enables `bup fuse`                   | Entry names encode total size, so the padding width changes when the file grows past a hex digit          |
| Split huge directories by sorted prefix, not by hash     | Keeps the directory listable in order; intermediate names are real filename prefixes                    | Shard occupancy follows the name distribution; [HAMT][unixfs] gets uniformity instead                     |
| Metadata in a sibling `.bupm` blob                       | git's five modes stay untouched; metadata-only changes do not reshape the tree                          | Two parallel structures, with documented ordering divergence                                              |
| git-annex: content **outside** the object graph          | Clone cost is independent of data size; content can live on S3, a USB disk, anywhere                    | No dedup below the file, no partial verification, and integrity is no longer a property of the commit     |
| git-annex: the backend name is _in_ the key              | Per-file, per-glob choice of hash; migration without rewriting history                                  | A key namespace that includes unverifiable members (`WORM`, `URL`)                                        |

## Sources

- [`DESIGN.md`][design] — hashsplitting, rollsum/stupidsum, the 13-bit test, fanout, tree splitting, `.bupm`
- [`lib/bup/bupsplit.h`][bupsplit-h] — `Rollsum`, `BUP_WINDOWBITS`, `ROLLSUM_CHAR_OFFSET`
- [`lib/bup/bupsplit.c`][bupsplit-c] — `rollsum_sum` and the self-test
- [`lib/bup/_hashsplit.c`][hashsplit-c] — `HashSplitter_roll`, the split masks, `extrabits`, `RecordHashSplitter`
- [`lib/bup/hashsplit.py`][hashsplit-py] — `BUP_BLOBBITS`, `fanout`/`MAX_PER_TREE`, `_squish`, `_make_shalist`, `configuration`
- [`lib/bup/git.py`][git-py] — `mangle_name`/`demangle_name` and the `.bup`/`.bupl` convention
- [git-annex internals][ga-internals] — `.git/annex/objects`, the `git-annex` branch
- [git-annex key format][ga-key] — the `BACKEND[-sNNNN][-mNNNN][-SNNNN-CNNNN]--NAME` grammar
- [git-annex backends][ga-backends] — `SHA256E`, `BLAKE3_256`, `XXH3`, `WORM`, `URL`, `VURL`
- [git-annex how it works][ga-how] — "a stupid filename and metadata tracker"
- [git-annex chunking][ga-chunking] — fixed-size, per-remote, transport-level chunking

<!-- References -->

[git-order]: ./git-objects.md#dimension-2--canonical-form-and-ordering
[casync]: ./casync.md
[bao]: ./bao-blake3.md
[unixfs]: ./ipfs-unixfs.md
[ostree]: ./ostree.md
[design]: https://github.com/bup/bup/blob/98b8a5a8146519797d9cc80d831d8ddf5f81b116/DESIGN.md
[bupsplit-h]: https://github.com/bup/bup/blob/98b8a5a8146519797d9cc80d831d8ddf5f81b116/lib/bup/bupsplit.h
[bupsplit-c]: https://github.com/bup/bup/blob/98b8a5a8146519797d9cc80d831d8ddf5f81b116/lib/bup/bupsplit.c
[hashsplit-c]: https://github.com/bup/bup/blob/98b8a5a8146519797d9cc80d831d8ddf5f81b116/lib/bup/_hashsplit.c
[hashsplit-py]: https://github.com/bup/bup/blob/98b8a5a8146519797d9cc80d831d8ddf5f81b116/lib/bup/hashsplit.py
[git-py]: https://github.com/bup/bup/blob/98b8a5a8146519797d9cc80d831d8ddf5f81b116/lib/bup/git.py
[ga-internals]: https://git-annex.branchable.com/internals/
[ga-key]: https://git-annex.branchable.com/internals/key_format/
[ga-backends]: https://git-annex.branchable.com/backends/
[ga-how]: https://git-annex.branchable.com/how_it_works/
[ga-chunking]: https://git-annex.branchable.com/chunking/
