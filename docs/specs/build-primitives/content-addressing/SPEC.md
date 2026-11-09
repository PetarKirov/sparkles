---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-09
---

# `sparkles:build-primitives` content addressing — Specification

## Abstract

Content addressing in `sparkles:build-primitives` gives a tree of files a
name computed from the tree itself: one digest over its entries' names,
kinds (file, directory or link), executable bits, link targets and file
contents, and over nothing else. The default name is the one Snix, a
reimplementation of Nix, gives a directory in its content-addressed store,
castore. It is BLAKE3 over a canonical directory encoding, and it names
each file by the same digest the iroh transfer library uses for a blob. The
same walk can also produce the SHA-256 of Nix's archive, or git's tree id,
which omits the empty directories git cannot hold. Each name equals the one
Snix, Nix or git computes for the same tree, and a walk reads each file
once, however many names it computes.

## Introduction

A build that caches its outputs, a store that deduplicates trees, and a
peer that publishes a directory all ask one question: what is the name of
exactly these files? For the same tree the name must be the same on every
host and every run. For any other tree it must differ, as far as its digest
resists collisions. It must also be cheap enough to compute on every build.
Where the tree crosses into another system, such as Nix's store, a git
repository or an iroh peer, the name must also be the one that system
computes, or the boundary cannot be checked.

Every tree format answers the question differently, and the differences are
where implementations go wrong. git sorts a directory as if its name ended
in `/`, so `a` comes after `a.b`. Nix's archive format, NAR, sorts by bytes,
while castore keeps directories, files and links in three separate lists.
git cannot represent an empty directory, and castore keeps one. A digest
computed in the order a directory happens to list differs between hosts.
None of these differences shows up until two implementations disagree on a
tree that exercises it.

The files to name come from a _fileset_: rules that select files beneath a
root directory. _Resolving_ a fileset walks the file system and finds its
members. This contract makes each format a _scheme_, a consumer that the
resolution hands one directory at a time, through an interface the
[filesets contract](../filesets/SPEC.md) calls the scheme seam. Each scheme
declares the entry order its format needs and the metadata it reads, such
as the executable bit, and the resolution delivers entries in that order;
a walk serving several schemes delivers one order and re-sorts each
directory for the rest.
The resolution decides which files are members; the scheme only encodes
them and reads their contents, without knowing which rules selected them.
Every encoding is checked against an independent implementation of the
same format, on trees chosen to exercise the differences above: a format
with no such oracle is not implemented.

The contract covers castore with BLAKE3, the default; NAR; and git's tree
with SHA-1 and SHA-256. It also covers a _tee_, which computes several of
these names in one walk, and a _supplied tree_: a file's BLAKE3 hash tree,
computed elsewhere and handed to a scheme so that the file can be named
without reading it. It does not cover storing blobs or directories,
parsing any of these formats, restoring a tree from a name, Nix store
paths, signatures, or publishing to iroh. Those belong to stores and
transports built on these names. Nor does it take a consistent snapshot of
a tree that is being written while it is named: holding the tree still, or
naming a snapshot of it, is the caller's job. Formats that nothing built on this
library needs, among them REAPI, OSTree, IPFS unixfs and casync, are out of
scope until something does.

Section 1 states the invariants. §§2–6 define the Merkle shell that
castore and git share, then castore, NAR, git and the tee. §7
defines the supplied tree, and §8 the surface in code. The oracles,
fixtures and evidence ledger are in [testing.md](./testing.md). The choices
behind the design are in [decisions.md](./decisions.md) and in the
[founding record](../filesets/decisions.md#a19-content-addressing-is-a-family-of-schemes-with-snix-castore-as-the-default)
among the filesets decisions. Delivery order is in the
[filesets plan](../filesets/PLAN.md#m6-content-addressing-schemes).

## 1. Invariants

Normative, and every later requirement is read against them.

1. **A name is a function of the tree alone.** It depends on the entries'
   names, kinds, executable bits, link targets and file contents, and on
   nothing else: not listing order, timestamps, ownership, permission bits
   beyond the executable one, the host, or how the fileset was written. The
   root's own name is not part of it. A format that cannot represent part
   of the tree names what it can: git omits empty directories (`CAG2`).
2. **Names are bytes.** No encoding folds case or normalizes Unicode. Two
   entries whose names differ in any byte are distinct entries.
3. **Every format has an oracle.** An encoding is accepted only when it
   equals an independent implementation of its format on the fixture set of
   [testing.md](./testing.md#fixtures).
4. **Schemes produce; they never parse.** No requirement here decodes a
   name, an archive or a directory message. The only untrusted input is the
   file system: names, link targets and contents are arbitrary bytes, and
   every encoding is total over them.
5. **A name covers bytes read once.** Each file is read in one pass, at the
   size its `stat` reported. A scheme that cannot read a file, or reads a
   different number of bytes, gives no name.

## 2. The Merkle shell (`CAM`)

Castore and git are Merkle encodings: a directory's id is a digest over its
entries, each naming a file by its _leaf_ id and a subdirectory by the id
its own encoding produced. They share one shell, a fold scheme in the sense
of [`FSS3`](../filesets/SPEC.md#_8-the-scheme-seam-fss).

**`CAM1` — The tree named is the tree handed over.** A scheme's result names
the tree the resolution hands it: the directories, members and links of
[§8 of the filesets contract](../filesets/SPEC.md#_8-the-scheme-seam-fss),
including the directories above the start roots, each holding only the way
to them, and the fileset root, which is always handed over. _Detection:_ a
fileset whose start roots lie beneath its root has the id of the tree
holding only its members.

**`CAM2` — Order is the format's.** Each encoding declares its entry order,
and its id is computed over its entries in that order and no other. An
encoding that declares no order does not compile
([`FSS5`](../filesets/SPEC.md#_8-the-scheme-seam-fss)). _Detection:_ on the
ordering fixture, git's id equals `git write-tree` and the same encoding
over bytewise order does not.

**`CAM3` — A file is read at its stated size.** The shell opens each member
file through its entry's reference, reads it to the end, and hands its leaf
the size its `stat` reported before any byte. If the bytes read differ in
number from that size, the resolution **must** fail with `schemeFailed` and
give no id. _Rationale:_ a file growing or shrinking while it is read would
otherwise be named by bytes that never existed together. A file rewritten in
place at the same size is not detected: a consistent snapshot is the
caller's (see the [introduction](#introduction)).

**`CAM4` — An incomplete tree has no id.** When the resolution reports an
entry it could not read
([`FSE2`](../filesets/SPEC.md#_10-errors-and-partial-results-fse)), the
scheme **must** abort, and the resolution fails with `schemeFailed`.
_Rationale:_ an id over the readable part names a tree that does not exist
([`FSE1`](../filesets/SPEC.md#_10-errors-and-partial-results-fse)).

**`CAM5` — Hashing allocates only to grow.** Once its buffers hold the
largest directory and the deepest path seen, a scheme **must not** allocate
to encode a directory or read a file. _Detection:_ the allocation
instrumentation of the filesets contract, run around a second resolution of
the same tree, counts zero calls.

## 3. Castore (`CAC`)

Castore is [Snix's](../../../research/content-addressing/tvix-castore.md)
content-addressed store format, and the default identity of a fileset. The
interoperability target is Snix at the revision the flake input `snix-src`
pins.

**`CAC1` — A file's id is BLAKE3 of its bytes.** A regular file's id
**must** be the 32-byte BLAKE3 digest of its contents, with no header, and
its size the number of bytes. _Rationale:_ an iroh blob has the same name,
so publishing a fileset hashes each file once.

**`CAC2` — A directory's id is BLAKE3 of its canonical message.** A
directory's id **must** be the 32-byte BLAKE3 digest of its `Directory`
message in canonical protobuf:

```proto
message Directory {
    repeated DirectoryEntry directories = 1;
    repeated FileEntry files = 2;
    repeated SymlinkEntry symlinks = 3;
}
message DirectoryEntry { bytes name = 1; bytes digest = 2; uint64 size = 3; }
message FileEntry { bytes name = 1; bytes digest = 2; uint64 size = 3; bool executable = 4; }
message SymlinkEntry { bytes name = 1; bytes target = 2; }
```

Each list is sorted by name, byte for byte. Canonical form writes fields in
field-number order, each list's entries consecutively, and omits a field at
its default value: a zero size, a `false` executable bit, an empty target.
_Detection:_ a hand-encoded message for a directory holding one entry of
each kind hashes to the encoder's id.

**`CAC3` — A directory's size counts what lies beneath it.** A directory's
size **must** be the sum over its entries of one, plus, for each
subdirectory, that subdirectory's size. A directory with no entries has size
zero.

**`CAC4` — Empty directories are kept.** A directory with no entries has an
id, the digest of the empty message, and its parent lists it. A fileset
handing over nothing at all names the empty directory.

**`CAC5` — The text form is Snix's.** The textual id **must** be `blake3-`
followed by the digest in standard base64 with padding, 51 characters in
all, as `snix-castore` prints it. _Detection:_ the empty directory reads
`blake3-rxNJufX5oaagQE3qNtzJSZvLJcmtwRK3zJqTyuQfMmI=`.

## 4. NAR (`CAN`)

NAR is [Nix's archive format](../../../research/content-addressing/nar.md),
the serialization that `nix-store --dump` writes and whose SHA-256 is a
store path's `NarHash`. The interoperability target is Nix's
`nix-archive-1`.

**`CAN1` — The bytes are Nix's.** The archive **must** be, byte for byte,
the one this grammar gives the tree, where each token is a string: its
length as a little-endian 64-bit integer, its bytes, and zeros padding it to
a multiple of 8.

```text
nar       = "nix-archive-1" node
node      = "(" "type" ( regular | symlink | directory ) ")"
regular   = "regular" [ "executable" "" ] "contents" contents
symlink   = "symlink" "target" target
directory = "directory" { "entry" "(" "name" name "node" node ")" }
```

A directory's entries appear in byte order of their names, so a later file
follows the whole subtree of an earlier subdirectory. _Detection:_ on every
fixture tree, the digest and length equal those of `nix-store --dump`.

**`CAN2` — The result is the digest and the length.** A NAR scheme's
result **must** carry the archive's digest by the scheme's hash and its
length in bytes; the archive itself is not retained. _Rationale:_ Nix
records `NarHash` and `NarSize` together, and a consumer storing one needs
the other.

**`CAN3` — The tree is the one handed over.** Directories above the start
roots appear as directories holding only the way to them, and a fileset
handing over nothing is the archive of the empty directory. Start roots are
written in path order, compared one component at a time, so `a/b` precedes
`a-c`, as the entry `a` precedes `a-c` in the directory holding both.

**`CAN4` — The text form is SRI.** A SHA-256 `NarHash` reads `sha256-`
followed by the digest in standard base64 with padding, as Nix prints it in
SRI form.

## 5. git trees (`CAG`)

git's [tree object](../../../research/content-addressing/git-objects.md)
names a directory in a repository. The interoperability target is
`git write-tree` after `git add -A -f`, in repositories using SHA-1 and
SHA-256 object ids. The SHA-1 id is for interoperability with SHA-1
repositories. It does not resist a deliberate collision, so a consumer that
needs that property uses castore or git with SHA-256.

**`CAG1` — The id is git's.** A directory's id **must** be git's object id
of a tree whose entries are `<mode> <name>\0<id>`, in git's tree order: a
directory's name compared as if it ended in `/`. Modes are `40000` for a
directory, `100755` for an executable file, `100644` for any other file, and
`120000` for a link, whose blob holds its target. Every object is hashed with
git's header, `<kind> <length>\0`, by the repository's hash.

**`CAG2` — Empty directories have no id.** A directory that holds no file
and no link, directly or beneath it, is omitted from its parent, as git's
index cannot hold one. A fileset with no members names the empty tree.

## 6. The tee (`CAT`)

A _tee_ computes several names in one walk. The contract defines one tee:
NAR with Merkle encodings beside it, so a store keeps a fileset's
identity and its `NarHash` without walking the tree twice.

**`CAT1` — Each part's name is its own.** Each name a tee returns **must**
equal the name its part computes alone over the same fileset. A part is a
Merkle encoding of §2, and the tee re-sorts each directory's entries from
NAR's order into the part's own. _Detection:_ a tee of castore and git
equals castore, git and NAR each computed alone, on every fixture tree.

**`CAT2` — A file is read once.** A tee **must** read each member file once,
and every part's leaf hears each of its bytes once. _Detection:_ a counting
leaf in a tee hears one start per file and the tree's total size in bytes.

**`CAT3` — The identity carries its `NarHash`.** The default tee **must**
return the castore id with the SHA-256 `NarHash` and `NarSize` beside it.
_Rationale:_ a Nix store asks for `NarHash` of every path it is given, and
recomputing it would re-read every file; see
[C1](./decisions.md#c1-narhash-is-stored-beside-the-identity-accepted).

## 7. A file's supplied tree (`CAO`)

BLAKE3 is itself a Merkle tree over 1024-byte chunks, and iroh stores the
interior of that tree beside a blob as an _outboard_, so that any range of
the blob can be verified against its root as it arrives
([bao](../../../research/content-addressing/bao-blake3.md)). This is the
type of the out-of-band tree that
[`FSS8`](../filesets/SPEC.md#_8-the-scheme-seam-fss) lets a scheme receive.

A supplied tree is three values: the file's root digest, its size, and its
outboard. iroh's outboard carries neither of the first two, so they travel
beside it.

**`CAO1` — A supplied tree names a file without reading it.** A castore
scheme given a supplied tree for a member file **must** take the file's id
and size from it, without reading the file's contents. _Detection:_ a file
whose tree is supplied is never opened, and the fileset's id equals the one
computed by reading it.

**`CAO2` — A range read later is verified.** Bytes of such a file that are
later read **must** be checked against the outboard before they are
surfaced; a chunk group that does not chain to the root is rejected.
_Detection:_ flipping one byte of a file with a supplied outboard makes a
read of its range fail, and no byte of the corrupt group is returned.

The outboard's layout and chunk-group size are open; see
[C2](./decisions.md#c2-the-outboard-s-layout-open).

## 8. Surface

Non-normative: the names in code of the parts above, all in
`sparkles.build_primitives.content_addressing`.

| Requirements  | Symbols                                                            |
| ------------- | ------------------------------------------------------------------ |
| `CAM1`–`CAM5` | `MerkleFold!(Dir, Leaf)`, `DigestLeaf`, `FramedLeaf`, `streamFile` |
| `CAC1`–`CAC5` | `CastoreScheme`, `CastoreDirectory`, `toCastoreText`               |
| `CAN1`–`CAN4` | `NarScheme!(H, Ref)`, `NarHash`, `toSri`                           |
| `CAG1`–`CAG2` | `GitTreeScheme!H`, `GitTree!H`, `toHex`                            |
| `CAT1`–`CAT3` | `NarScheme!(H, Ref, Dirs)`, `WithNar`, `CastoreNar`                |

A directory encoding is a struct with `enum order`, `alias Id`, `begin`,
`directory`, `file`, `symlink` and `seal`, and optionally `enum metadata`
and `alias Leaf`. A leaf has `alias Id`, `start(size)`, `put(bytes)` and
`finish`. The module documentation of `content_addressing/merkle.d` lists
each member's signature.
