---
status: accepted
owner: sparkles:build-primitives
reviewed: 2026-11-09
---

# Content addressing — Decisions

The founding record is the filesets decision
[A19](../filesets/decisions.md#a19-content-addressing-is-a-family-of-schemes-with-snix-castore-as-the-default):
content addressing is a family of schemes on the fileset seam, castore with
BLAKE3 is the default identity, and every instance has an oracle. The records
below follow from it. Each states its question, the alternatives, the choice
and when to revisit it; **accepted** records are the owner's decisions,
**proposed** ones await them, and **open** ones have no proposal yet.

## C1: `NarHash` is stored beside the identity (accepted)

_Was open as the filesets record D2. Accepted by the owner on 2026-11-09._

**Question.** A Nix store asks for the `NarHash` and `NarSize` of every path
it is given. Is that hash computed once, when the fileset is named, and kept
with its identity, or recomputed from the stored tree when a Nix boundary
asks?

**Alternatives.**

- **Recompute on demand.** Keep only the castore identity, and render the
  NAR from the stored blobs and directories when asked. Nothing is spent on
  SHA-256 by a consumer that never meets Nix.
- **Store it.** Compute the NAR in the same walk that names the fileset, and
  keep the digest and length beside the identity.

**Evidence.** Snix stores `nar_size` and `nar_sha256` in its `PathInfo`, and
makes `NarCalculationService` a trait so that a remote store can answer
instead of re-walking the tree and re-streaming every blob
([castore research](../../../research/content-addressing/tvix-castore.md),
[recommendation 2](../../../research/content-addressing/recommendations.md#_2-narhash-should-be-stored-not-merely-recomputable)).
The tee of [`CAT2`](./SPEC.md#_6-the-tee-cat) computes both in one walk that
reads each file once, so storing costs one SHA-256 pass over bytes already
in memory, not a second read.

**Choice.** Store it. The default tee, `CastoreNar`, returns the castore id
with `NarHash` and `NarSize` beside it ([`CAT3`](./SPEC.md#_6-the-tee-cat)).
A consumer that never meets Nix names its filesets by castore alone, and
pays nothing for NAR. Where the pair is kept is the store's.

**Revisit** if a store must answer for trees it named by castore alone. It
then has to recompute, as Snix's trait allows, and the contract would need a
NAR rendered from stored blobs rather than from a walk.

## C2: The outboard's layout (accepted)

_Accepted by the owner on 2026-11-09._

**Question.** [`CAO1` and `CAO2`](./SPEC.md#_7-a-file-s-supplied-tree-cao)
need a supplied tree to have one layout. Which one, at which chunk-group
size?

**Alternatives.**

- **iroh's pre-order outboard at 16 KiB chunk groups.** Records of 64 bytes
  in pre-order, with no size prefix: `(blocks - 1) * 64` bytes for
  `blocks = ceil(size / 16384)`. It is the layout `iroh-blobs` keeps on
  disk, so a blob fetched from iroh arrives with its tree
  ([bao-tree](../../../research/iroh/bao-tree.md)).
- **The `bao` crate's outboard.** 1024-byte chunks with a length prefix: an
  outboard 16 times larger, which no store in this design produces.

**Constraints.** The oracle must be independent: `bao-tree`'s own encoder,
or `sendme`, both from nixpkgs. Producing either layout needs BLAKE3's
chaining values for whole subtrees, which `sparkles.base.hash.blake3`
computed internally but did not expose before this record.

**Choice.** iroh's layout: 16 KiB chunk groups, one record per parent node
of BLAKE3's tree over the groups, in pre-order, with no size prefix. The
root and the size travel beside it, in `SuppliedTree`. Publishing to iroh
is the consumer that motivates a supplied tree, and with this layout a
blob's outboard is the file iroh keeps, byte for byte, so nothing is
converted on the way in or out.

`sparkles.base.hash.blake3` now exposes what the layout needs: a hasher
placed at an offset of a larger input (`setInputOffset`), its chaining
value (`finishNonRoot`), and the merge of two (`blake3ParentCv`,
`blake3ParentRoot`). The oracle is `bao-tree`'s own encoder, version
0.17.0, built by `packages.bao-outboard`: `sendme` keeps the
same files, but only inside a store it serves to the network.

A supplied tree is checked as far as it can be without the file: its
outboard must be as long as its size implies, and its top record must
merge into its root. A tree that fails either check fails the resolution;
it is not silently replaced by reading the file. Whether the rest of the
outboard, and the file, match the root is learned only when the file is
read, which is what `CAO2` guards.

**Revisit** if iroh changes its block size, or a second consumer of
supplied trees needs another layout, such as APK v4's
`.apk.idsig`, whose tree is SHA-256 over 4 KiB blocks: that would be another
`Supply` for the same fold, not a change to this one.

## C3: Memberless directories in an id (accepted)

_Accepted by the owner on 2026-11-09._

**Question.** The resolution hands a scheme every directory it entered, and
reports the memberless ones as empty directories
([`FSV4`](../filesets/SPEC.md#4-the-fileset-value-fsv),
[A13](../filesets/decisions.md#a13-an-empty-directory-is-a-memberless-leaf-of-the-walk)).
Castore and NAR record an empty directory, so each such directory becomes
part of the id. With an unanchored pattern, the walk enters every directory,
because a match could lie in any of them. On the tree
`a/b/x a/b/d/y a/c a-c/z q`, `q` and `/q` select the same single file. `/q`
has the id of the tree holding only `q`. `q` also hands over `a`, `a/b`,
`a/b/d` and `a-c`, each holding nothing, and before this record its castore
id differed. That
broke [invariant 1](./SPEC.md#_1-invariants): a name must not depend on how
the fileset was written. git trees are unaffected, since git omits empty
directories. Which directories belong to the tree a fileset names?

**Alternatives.**

- **Members only.** A directory is part of the tree only on the way to a
  member; the fileset root is always part of it. Since
  [`FSV3`](../filesets/SPEC.md#4-the-fileset-value-fsv) makes a fileset a
  set of files, this is the only reading under which invariant 1 holds for
  every spelling. A truly empty directory is dropped even under `everything`,
  as nixpkgs' `lib.fileset.toSource` drops it; `FSV4`'s report still gives a
  consumer that recreates the shape what it needs. The oracle fixtures would
  materialize the members' tree, not the literal.
- **Memberless directories under a whole subtree.** Keep a memberless
  directory only beneath an `acceptAll` verdict, the alternative A13 names:
  `everything` and `src/**` keep `empty/`, while a directory searched for an
  unanchored pattern is dropped. This keeps today's fixtures. But a verdict
  is a property of the plan, not of the set of files: `src/**` and a
  spelling that selects the same files without reaching `acceptAll` would
  still differ. Invariant 1 would have to name the plan.
- **Keep the walk's directories.** Reword invariant 1 so that an id names the
  walk. Two equal filesets would then have different ids, which defeats
  caching by id.

**Choice.** Members only. The seam is unchanged: it still hands a scheme
every directory the walk entered, as `FSV4`'s report needs. Each scheme
leaves out what holds no member. The Merkle fold's value carries, beside a
directory's id, whether a member lies beneath it, and a parent skips a
subdirectory without one. NAR defers a directory's header until the first
file or link beneath it is written, so a directory that closes with nothing
written leaves no trace in the archive or in a tee's ids. The fileset root
is always written. The filesets contract's A13 question is settled for ids,
whatever `FSV4`'s report keeps.

**Revisit** if a consumer must reproduce a tree's empty directories from
its name alone. It would then need a scheme that declares it keeps them,
and a name that depends on the fileset's spelling.

## C4: A supplied tree is checked against its file's size

[`CAO1`](./SPEC.md#_7-a-file-s-supplied-tree-cao) checked that a supplied
tree holds together, its outboard the length its size implies and its top
record merging into its root, but never that the size is the file's. A
sidecar left from an earlier version of the file passes both checks and
names that version. An external review found the gap.

The fold now declares `FsoMetadata.size` when it is given a supply, and a
tree whose size differs from the one the member's `stat` reports fails the
resolution, as a tree that does not chain does. The size costs nothing
extra: it comes from the `stat` the fold already issues for the executable
bit. A tree of the right size but stale content is still beyond this check,
and is caught by `CAO2` when a range is read.
