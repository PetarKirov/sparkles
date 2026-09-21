# Synthesis & recommendations

The capstone: what twenty-one systems agree and disagree about, the seam
falsification gate, the two places this survey **contradicted** a decision we
had already made, and what
[`sparkles:build-primitives`][bp] should adopt.

**Last reviewed:** September 21, 2026

The per-subject breakdown by composition, ordering, metadata floor and
verification granularity lives in the [umbrella's taxonomy tables][index]; this
page argues rather than tabulates.

---

## Axis 1 — what is in the identity

The field agrees on the exclusion and disagrees on everything above it. **Every
subject but two excludes timestamps** — [Nix][nar] because they "cause FSOs
that Nix should consider equal to hash to different values on different
machines", [OSTree][ostree] because hardlinked checkouts must compare as up to
date. The exceptions are instructive: [REAPI][reapi] can carry an `mtime` as an
optional, server-declared node property, and [OCI][oci] carries one because tar
does and nobody stopped it.

Above that floor the spread is the whole design space — from [Bao's][bao] and
[Venti's][venti] _nothing at all_, through one executable bit
([NAR][nar], [Snix][castore]), to [OSTree's][ostree] uid/gid/mode/xattrs
_inside the content hash_, to [casync's][casync] genuinely unusual answer: the
node model is a **feature flag**, so the same tool emits a timestamp-free
archive or a fully faithful one.

[Reproducible archives][repro] supplies the negative proof. Retrofitting
canonicity onto tar and zip converges on NAR's node model **by deletion** —
`strip-nondeterminism`'s `zip.pm` and `ar.pm` both collapse modes to
`755`/`644` and uid/gid to `0`, arriving at name + bytes + one executable bit by
overwriting fields rather than by not having them.

## Axis 2 — entry ordering

**No single canonical order exists.** Four canonical answers, two deliberately
non-canonical ones, one subject that never orders, and one that versioned its
comparator — [tabulated in the umbrella][index-order]. The two that matter most
disagree on real inputs: given a directory `a` and a file `a.b`, `.` is `0x2E`
and `/` is `0x2F`, so git orders `a.b` first while a byte-wise sort orders `a`
first ([worked against real git][git-order]).

**The `/`-suffix rule now has four independent implementations** — git's own
`base_name_compare`, Nix's `git.cc` (whose header comment cites irmin hitting
it too), Software Heritage's `directory_entry_sort_key` (which appends `b"/"`
rather than substituting, arriving at the same function from the other side),
and [bup][bup], whose `.bupm` layout explicitly accounts for it. A claim that
survives four reimplementations is as solid as this catalog gets.

It is also not free. Because the implicit slash can separate two spellings of
one name, git's duplicate detection needs a **stack** rather than an
adjacent-pair check — `fsck.c` documents the `foo` / `foo.bar` / `foo.bar/` /
`foo/` case — where [NAR's][nar] `name <= prevName` suffices. The partitioned
answers ([OSTree's][ostree] two arrays, [REAPI's][reapi] and [Snix's][castore]
three) make the question structurally unaskable.

[Venti][venti] contributes the hazard's endgame: `vac`'s metablock selects its
comparison predicate from the block magic (`mb->unbotch`), because a
known-wrong comparator could not be fixed in place — the archives are
immutable. An ordering bug in a content-addressed format is permanent.

## Axis 3 — serial versus Merkle

Everything a build system wants follows from the Merkle side: subtree caching,
`O(depth)` rehash after a one-file edit, independent verification of a
fragment, parallel hashing across files. [Mercurial][hg] is the field's
controlled experiment — it shipped a flat whole-tree manifest, hit
`O(|repo files|)` parse cost, and moved to per-directory trees, stating the
bound in its own retrospective: `O(|changed files| * |directory size| *
|directory depth|)`, which with capped fan-out and depth is `O(|changed
files|)`.

[Venti][venti] settles a question the concepts page could only assert. Its
directories are "a special file" of concatenated 40-byte `VtEntry` structures,
so its level-1 tree **is** its level-2 pointer tree with a different block-type
base. The levels do not nest; they are the same machine run twice.

## Axis 4 — the level-2 surprise

Intra-file Merkle trees are neither new nor peer-to-peer-specific.
[Venti][venti] had pointer-block trees in 2002; [REAPI][reapi] added
`SHA256TREE` in 2023 for chunk-level integrity _and_ SIMD parallelism that a
serial SHA-256 cannot offer.

The design consequence is concrete and load-bearing: **any seam that hands a
scheme a whole-file digest, or a fixed-size push stream of content, forecloses
this entire class.** A scheme must read its own bytes, in its own order, at its
own concurrency.

[Snix][castore] then supplies the best answer in the survey to _where_ chunking
belongs. Blob identity is plain BLAKE3 of the raw bytes — no length prefix, no
`blob <len>\0` framing — with FastCDC running strictly _below_ identity as a
storage and transport concern. Their write-up names the disease that
[casync][casync] and [unixfs][ipfs] both have:

> The chunking parameters, and the "topology" of the graph structure itself
> "bleeds" into the root hash.

Keep chunking below the identity and the parameters stop being part of the
answer.

## Axis 5 — what travels with a digest

[REAPI][reapi] puts `size_bytes` inside `Digest`; [iroh][bao] verifies that a
validated final leaf ends exactly at the claimed size; [Snix][castore]
independently carries a `size` at **both** levels (`FileEntry.size`,
`DirectoryEntry.size`). Three independent derivations of the same guard.

The counterweight is [Software Heritage][swh], which carries no length at all
and welds SHA-1 into the identifier grammar itself
(`<object_id> ::= 40 * <hex_digit>`), with agility available only by breaking
the scheme version. It is the strictest position in the survey — and it
length-prefixes exactly one thing, snapshot alias targets, for disambiguation
rather than truncation detection. That yields a crisp rule: **fixed-width
digests are what buy delimiter-free concatenation; any entry kind with a
variable-length target needs its own length field.**

Genuine algorithm agility exists only in [REAPI][reapi] (seven functions,
negotiated) and the [CID][ipfs] family (multihash-tagged, so a digest stays
interpretable when separated from the system that made it).

## Axis 6 — partial verification

Falls out of axes 3 and 4 — with one distinction the survey earned the hard
way. A **tree** verifies a 16 KiB range against a 32-byte root with nothing
else transmitted, because the geometry follows from the length. An **index**
([eStargz and SOCI][estargz]) is a flat list of per-chunk digests that must be
fetched _whole_ before any byte can be checked, and whose own integrity hangs
off an annotation or a side artifact. **The index gives depth-2 trust; the tree
gives `O(log n)`.**

[APK v4][apk] adds the dimension nobody else has: the tree can be a **shipped
artifact**. A `.apk.idsig` comes in `complete` and `stripped` forms, so a
verifier can check a range for the cost of a signature over a few hundred bytes
instead of a full pass. A seam should let a level-2 tree **arrive out of band**
rather than assuming each consumer recomputes one.

---

## What the field agrees on

1. **Timestamps are not identity** — every subject but [REAPI][reapi] (optional)
   and [OCI][oci] (by accident).
2. **Canonical form must be specified and checked.** [NAR][nar] rejects
   unsorted input at the parser; [git][git] names each violation as an `fsck`
   code; [REAPI][reapi] makes "canonical form" a normative term.
3. **Symlinks are values, not links.** Every subject stores the target string
   and refuses to follow it.
4. **Byte-wise comparison, never locale or case folding** — in every ordering
   answer that orders at all.

## What it does not agree on

1. **Ordering** — nine answers (axis 2).
2. **The metadata floor** — from nothing to uid/gid/mode/xattrs.
3. **Case and duplicate collisions** — five answers, and only one detects at
   ingest without damaging the identity:

   | System         | Behaviour                                                                                     |
   | -------------- | --------------------------------------------------------------------------------------------- |
   | [NAR][nar]     | name mangling: `~nix~case~hack~` + counter on restore, stripped on dump                       |
   | [git][git]     | permitted silently; fails at checkout on a case-insensitive filesystem                        |
   | [REAPI][reapi] | "legal … but the Action may be rejected by the remote system upon execution"                  |
   | [OCI][oci]     | whatever tar did; discovered on extraction                                                    |
   | [SWH][swh]     | **detect at ingest, keep the digest byte-exact via `raw_manifest`, rename only in the model** |

   Software Heritage's answer deserves its own line because it is the only one
   that does not move the failure away from its cause _and_ does not sacrifice
   fidelity: `compute_hash` returns `sha1(raw_manifest)` whenever a raw
   manifest is present, and `check()` refuses one that was not needed.

4. **Whether a canonical form can be enforced at all.** [Venti's][venti] zero
   truncation — trailing zero bytes stripped from data blocks, trailing zero
   scores from pointer blocks — is a _value_ normalization rather than an
   ordering or framing rule, and it is the one canonical form in the catalog
   the format **cannot** enforce: the server cannot distinguish a truncated
   block from an untruncated one. It is a client convention.

---

## What this survey contradicted

Two earlier decisions did not survive contact with the evidence, and one needs
rewording.

### 1. The git-shaped identity is a genuine fork, not an obvious choice

We chose a git-shaped Merkle identity in large part for its two independent
oracles (`git write-tree`, plus Nix's second implementation).
**[Snix][castore] — a full Nix reimplementation, in production — deliberately
went the other way**, rejecting git's encoding as "very binary, error-prone and
'made-to-be-read-and-written-from-C'" and judging that SHA-1 "isn't really a
hash function to fundamentally base everything on in 2023". It took
[REAPI's][reapi] three-sorted-arrays partition and BLAKE3 instead.

The trade is now explicit:

|                                | git-shaped                             | REAPI-shaped (Snix)                                        |
| ------------------------------ | -------------------------------------- | ---------------------------------------------------------- |
| Ordering hazard (`a` vs `a.b`) | present; needs the `/`-suffix trick    | **structurally absent**                                    |
| Independent oracle             | **`git write-tree`, on every machine** | none comparable                                            |
| Hash function                  | SHA-1 or SHA-256, repository-wide      | BLAKE3, parallel by construction                           |
| Canonicity rests on            | a byte format                          | deterministic protobuf (which Snix itself flags as a risk) |

This is a decision to make deliberately rather than inherit. It does not change
the _shape_ of the recommendation — Merkle internally, NAR at the boundary —
only which Merkle.

### 2. `NarHash` should be stored, not merely recomputable

The earlier wording said NAR's serial cost "is irrelevant there because the
bytes are being streamed anyway". That holds **on ingest only**. Snix makes
`NarCalculationService` a _trait_ precisely so a remote store can answer
instead of re-walking the tree and re-streaming every blob, and its `PathInfo`
carries `nar_size` and `nar_sha256` as stored fields. Store them beside the
Merkle identity.

### 3. "Error at hash time" is not the only honest answer to a collision

Recommendation 6 below proposed refusing a colliding tree, on the grounds that
the field's other answers all defer the failure. [SWH's `raw_manifest`][swh]
shows a fourth position — repair the model, never the identity — which matters
for any consumer that must reproduce an upstream digest exactly and therefore
cannot refuse the tree.

---

## The falsification gate

The seam declares, per scheme: a **required entry ordering**, a **metadata
mask**, a **traversal mode** (pre-order stream or post-order fold), and **no
content requests at all** — schemes own their own byte I/O. Subjects were run
through it on paper before any of it was written.

| Subject                  | Verdict                                 | What it found                                                                         |
| ------------------------ | --------------------------------------- | ------------------------------------------------------------------------------------- |
| [REAPI][reapi]           | ✅ fold, byte-wise, partitioned by kind | **Finding 1** — the metadata mask must admit `mtime`                                  |
| [Bao][bao]               | ✅ level-2 only, scheme-owned I/O       | Justifies both "no pushed content" and "levels are independent"                       |
| [OSTree][ostree]         | ⚠️                                      | **Finding 2** — the request vocabulary needs an extension point (xattrs)              |
| [NAR][nar] vs [git][git] | ✅ both                                 | **Finding 3** — traversal mode decides whether a scheme scales with cores             |
| [Snix][castore]          | ✅ fold, three arrays, BLAKE3           | **Finding 4** — a stored `NarHash` field, not a recomputation                         |
| [APK v4][apk]            | ⚠️                                      | **Finding 5** — a scheme must be able to _receive_ a level-2 tree, not only build one |
| [Tahoe][tahoe]           | ❌ out of scope                         | **Finding 6** — see below                                                             |

> **Finding 1 — the metadata mask must admit `mtime`.** Timestamps stay out of
> _identity_. But a scheme cannot synthesize what the walk never requested, and
> the `mtime` arrives in the same `statx` already issued for the executable
> bit, so admitting it to the mask costs nothing.
>
> **Finding 2 — the request vocabulary must be open.** OSTree's identity
> includes xattrs, which need `listxattr`/`getxattr` — outside
> `readDir`/`stat`/`readlink`/`readFile`. Unsatisfiable requests should be a
> typed error, not a silent omission. Xattrs stay unimplemented in v1.
>
> **Finding 3 — traversal mode is a performance decision.** Pre-order streaming
> cannot use the walk's parallelism; post-order folding can.
>
> **Finding 4 — `NarHash`/`NarSize` are stored fields.**
>
> **Finding 5 — a tree may arrive out of band.** APK v4 ships the Merkle tree
> beside the artifact; iroh stores an outboard. The seam should not assume the
> verifier hashes the bytes itself.
>
> **Finding 6 — Tahoe is the boundary of the model, and usefully so.** Erasure
> coding means **no stored artifact hashes to anything in the address**, and
> `k`, `N` and segment size sit inside the key derivation, so identical bytes
> under different encoding policy get a different capability. A capability
> names _a recipe with a fixed output_, not a byte string. Our seam assumes a
> digest names bytes; it does not generalize to this, and should say so rather
> than pretend.

---

## Recommendations for `sparkles:build-primitives`

1. **Internal identity: a Merkle tree hash** — subtree values are what make
   incremental rehash, cross-run caching and parallel hashing possible. **Which
   Merkle is now an open decision** (see [the contradiction][contra-1]):
   git-shaped buys `git write-tree` as a free oracle; REAPI/Snix-shaped buys
   structural immunity to the ordering hazard and BLAKE3.
2. **`NarHash`/`NarSize` computed at the Nix boundary and then _stored_** beside
   the Merkle identity, not recomputed on demand.
3. **Name every ordering separately** — `narOrder`, `gitTreeOrder`,
   `partitionedOrder` — and pin the differences with the `a` versus `a.b`
   fixture. Never write a `canonicalOrder`.
4. **Admit `none` as an ordering** for consumers that rank rather than hash,
   and let the ordering choice select the emission shape (streamed entries
   versus a buffered sorted batch). Exclude `none` at compile time for fold
   schemes.
5. **Identity is byte-exact** — no case folding, no normalization. Unanimous in
   the field, and the only position that interoperates.
6. **Detect case and normalization collisions at hash time** and return an
   `Expected` error naming both entries — _with_ an escape hatch in the shape
   of [SWH's `raw_manifest`][swh] for a consumer that must reproduce an
   upstream digest exactly.
7. **Carry the length beside the digest, at both levels.** Three independent
   derivations; nearly free.
8. **Keep content out of the fileset machine**, keep the metadata mask and
   request vocabulary **open**, and allow a level-2 tree to arrive out of band.
9. **Copy NAR's bounds** — `narMaxDepth` 64, `narMaxTag` 32, `narMaxName` 255.
   Snix independently chose `MAX_NAME_LEN = 255` with the identical rationale.
10. **Keep chunking strictly below identity** if chunking is ever added, so its
    parameters never bleed into the root hash.
11. **The subtree cache must be an optimization, never an authority.**
    [git's `cache-tree`][cachetree] is advisory — a lost node costs time.
    [ccache's direct-mode manifest][caches] _is_ the authority for a hit, and
    its documented hole (a header that "would have been used if it existed" is
    never recorded) is a false "unchanged", which is the one error class our
    staleness rule forbids.
12. **Record provenance beside the digest, never inside it** — the SWHID
    qualifier lesson. Dedup erases the path and origin a consumer may need.

## Out of scope, and why

- **Store paths, `.narinfo`, signatures, compression** — [`sparkles:nix`][nixspec]
  binds `libnixstore-c` and can compute these for real.
- **Typed-data Merkleization** (Ethereum SSZ) — consensus objects, not file
  system objects.
- **Confidentiality-preserving addressing** ([Tahoe][tahoe]) — a different
  problem, and finding 6 says why it does not fit the seam.

<!-- References -->

[index]: ./index.md
[index-order]: ./index.md#by-entry-ordering
[concepts]: ./concepts.md
[nar]: ./nar.md
[git]: ./git-objects.md
[git-order]: ./git-objects.md#dimension-2--canonical-form-and-ordering
[cachetree]: ./git-cache-tree.md
[nixgit]: ./nix-git-hashing.md
[castore]: ./tvix-castore.md
[hg]: ./mercurial-sapling-manifests.md
[reapi]: ./reapi.md
[ostree]: ./ostree.md
[swh]: ./software-heritage.md
[bup]: ./bup-git-annex.md
[casync]: ./casync.md
[ipfs]: ./ipfs-unixfs.md
[bao]: ./bao-blake3.md
[tahoe]: ./tahoe-lafs.md
[oci]: ./oci-layers.md
[estargz]: ./estargz-soci.md
[cfs]: ./composefs-fs-verity.md
[apk]: ./apk-dm-verity.md
[repro]: ./reproducible-archives.md
[caches]: ./build-input-caches.md
[venti]: ./venti.md
[contra-1]: #1-the-git-shaped-identity-is-a-genuine-fork-not-an-obvious-choice
[bp]: ../../../libs/build-primitives/src/sparkles/build_primitives/gitignore.d
[nixspec]: ../../specs/nix/SPEC.md
