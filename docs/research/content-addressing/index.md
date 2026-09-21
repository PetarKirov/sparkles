# Content Addressing of File System Objects

A primary-source survey of how twenty-one systems turn a tree of files into a
digest — from Plan 9's [Venti][venti] in 2002 through [Nix][nar], [git][git],
[OSTree][ostree] and [Bazel's REAPI][reapi] to the intra-file Merkle trees of
[Bao][bao] and [fs-verity][cfs] — and of the two places the field's own
experience says it goes wrong: [tar's absent canonical form][repro] and
[cache keys mistaken for content addresses][caches].

The evidence base for the content-addressing layer of
[`sparkles:build-primitives`][bp], and the falsification gate for the scheme
seam that layer is designed around.

This survey answers nine questions:

1. **Serial serialization or Merkle DAG?** Overwhelmingly Merkle, and
   everything a build system wants — subtree caching, `O(depth)` rehash,
   independent verification, parallel hashing — lives on that side of the line.
   See [axis 3][axis3].
2. **Is there one canonical entry order?** **No.** Four canonical answers, two
   deliberately non-canonical ones, and one subject that never orders at all.
   Two of the four disagree on inputs as ordinary as a directory `a` beside a
   file `a.b`. See [axis 2][axis2] and the [worked case][git-order].
3. **What belongs inside an identity?** Timestamps: almost unanimously not.
   Everything above that floor: no agreement whatsoever. See [axis 1][axis1].
4. **Are intra-file chunk trees a peer-to-peer curiosity?** No — [REAPI][reapi]
   put one in a build protocol in 2023, and [Venti][venti] had one in 2002. See
   [axis 4][axis4].
5. **Can canonical form be retrofitted onto a format that lacks it?** Only
   partly, and [the people who tried][repro] have a list of what provably
   cannot be fixed. [OCI][oci] is the ecosystem-scale demonstration.
6. **What does a level-2 _tree_ buy over an _index_ of chunk digests?**
   `O(log n)` verification against a 32-byte root versus depth-2 trust
   requiring the whole index first. See [index versus tree][idx-tree].
7. **How does the field handle case and duplicate collisions?** Five ways, only
   one of which detects at ingest without corrupting the identity. See
   [the disagreements][disagree].
8. **Is a cache key a content address?** No, and [ccache's `sloppiness`
   list][caches] is a published taxonomy of exactly how they differ.
9. **What should `sparkles:build-primitives` adopt?** See the
   [recommendations][rec] — including the two places this survey
   **contradicted** an earlier decision.

**Last reviewed:** September 21, 2026

> [!NOTE]
> **Scope.** This tree is about turning a _tree of files_ into a _digest_. It
> is not about **selecting** the files — that is
> [Fileset & File-Selection Query Languages][fsl] — nor about the store,
> signature and cache layers above the digest, which [`sparkles:nix`][nixspec]
> reaches through `libnixstore-c` rather than reimplementing.
>
> Deliberately excluded, and named so they are not re-derived: **typed-data
> Merkleization** (Ethereum SSZ) addresses consensus objects rather than file
> system objects. **Content-defined chunking** is not excluded but is treated
> as what it is — a level-2 boundary _policy_, surveyed where a subject uses
> one ([casync][casync], [bup][bup], [unixfs][ipfs], [Snix][castore]).
> Deferred, noted not omitted: Perkeep, restic/borg, Go's checksum database
> (a Merkle _log_, a different shape), and git packfile delta encoding
> (storage beneath identity).

---

## Master catalog

| Subject                         | Ecosystem                   | Level 1 (directory tree)                                | Level 2 (file bytes)                            | Entry ordering                         | Digest                            | Link        |
| ------------------------------- | --------------------------- | ------------------------------------------------------- | ----------------------------------------------- | -------------------------------------- | --------------------------------- | ----------- |
| **Venti**                       | Plan 9                      | pointer-block tree; directories are _files_             | same pointer tree                               | n/a — no names                         | SHA-1 "score"                     | [venti]     |
| **Nix Archive (NAR)**           | Nix                         | serial serialization                                    | whole blob, inline                              | byte-wise, one sequence                | SHA-256 over the stream           | [nar]       |
| **Git objects**                 | Git                         | Merkle DAG                                              | whole blob                                      | byte-wise **+ implicit `/`**           | SHA-1 / SHA-256                   | [git]       |
| **Git `cache-tree`**            | Git                         | — (incremental _maintenance_ of the above)              | —                                               | —                                      | —                                 | [cachetree] |
| **Nix `git-hashing`**           | Nix (experimental)          | git trees over Nix's FSO model                          | git blobs                                       | git's                                  | SHA-1 / SHA-256                   | [nixgit]    |
| **Snix `castore`**              | Snix (Nix reimplementation) | Merkle DAG, protobuf `Directory`                        | **plain BLAKE3**; FastCDC _below_ identity      | byte-wise, three arrays                | BLAKE3                            | [castore]   |
| **Mercurial → Sapling**         | Mercurial, Sapling          | **flat whole-tree listing**, then per-directory trees   | per-file revlog                                 | sorted rows                            | SHA-1 **over parents + content**  | [hg]        |
| **Bazel REAPI**                 | Bazel, Buck2, Pants         | Merkle DAG of protobuf `Directory`                      | whole blob **or `SHA256TREE`**                  | byte-wise, three arrays                | `{hash, size_bytes}`, 7 functions | [reapi]     |
| **OSTree**                      | Linux OS images             | Merkle DAG (`dirtree` + `dirmeta`)                      | whole blob + header                             | byte-wise, two arrays                  | SHA-256                           | [ostree]    |
| **Software Heritage**           | Source-code archive         | Merkle DAG **above** the tree (`dir`→`rev`→`rel`→`snp`) | `sha1_git`                                      | git's, reimplemented                   | SHA-1, fixed by the grammar       | [swh]       |
| **bup / git-annex**             | Backup                      | git trees, with **fanout**                              | **content-defined chunks as git blobs**         | git's                                  | SHA-1                             | [bup]       |
| **casync / desync**             | systemd ecosystem           | `catar`, a canonical serial format                      | **CDC across file boundaries**                  | canonical                              | SHA-512/256 per chunk             | [casync]    |
| **IPFS unixfs / CID**           | IPFS, Filecoin              | DAG-PB; huge directories **HAMT-sharded**               | pluggable chunker                               | n/a (links, not sorted names)          | **self-describing CID**           | [ipfs]      |
| **Bao / BLAKE3**                | iroh                        | **none**                                                | **Merkle chunk tree**                           | n/a                                    | BLAKE3, 32 raw bytes              | [bao]       |
| **Tahoe-LAFS**                  | Distributed storage         | mutable dirnodes; **no ordering at all**                | three-tier tree over _erasure-coded ciphertext_ | none                                   | capability, not a hash            | [tahoe]     |
| **OCI image layers**            | Containers                  | an ordered **chain** of tar layers                      | whole tar archive                               | **unspecified**                        | `sha256:` ×3 identities           | [oci]       |
| **eStargz / SOCI**              | Containers                  | tar, made seekable                                      | per-chunk digests in an **index**               | **workload-derived**                   | TOC digest / zTOC                 | [estargz]   |
| **composefs + fs-verity**       | Linux, OSTree               | EROFS image over a shared store                         | **kernel-built, kernel-enforced** Merkle tree   | image layout                           | parameterized descriptor digest   | [cfs]       |
| **dm-verity / APK v4**          | Linux, Android              | **none** — numbered blocks                              | Merkle tree; **shipped** in `.apk.idsig`        | n/a                                    | parameterized, signed root        | [apk]       |
| **Reproducible archives**       | Debian, wider ecosystem     | — (a _retrofit_ onto tar/zip/ar/cpio)                   | —                                               | only two formats can be ordered at all | —                                 | [repro]     |
| **ccache / sccache / LLVM CAS** | Build caches                | — (inputs, not trees)                                   | —                                               | —                                      | BLAKE3 key, salted                | [caches]    |

Shared vocabulary — file system object, the level-1/level-2 split, canonical
form, parameterized digests, identity versus provenance, index versus tree — is
defined once in [concepts][concepts].

## By level-1 composition

| Composition             | Systems                                                                                                                            | Consequence                                                                                  |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------- |
| Serial serialization    | [NAR][nar], [casync][casync]                                                                                                       | No subtree values; sharing must be recovered _below_ the tree, at chunk level, or not at all |
| Flat whole-tree listing | [Mercurial][hg]                                                                                                                    | `O(                                                                                          | repo files | )` to parse — the failure that forced the move to trees |
| Merkle DAG              | [git][git], [Nix `git-hashing`][nixgit], [Snix][castore], [REAPI][reapi], [OSTree][ostree], [SWH][swh], [bup][bup], [unixfs][ipfs] | Subtree identity, `O(depth)` rehash, object-granular verification                            |
| Chain, not tree         | [OCI][oci]                                                                                                                         | `O(n)` invalidation in the layer count; order-dependent semantics                            |
| None — level 2 only     | [Bao][bao], [dm-verity][apk]                                                                                                       | Proof the two levels are independent                                                         |
| Level 2 _is_ level 1    | [Venti][venti]                                                                                                                     | The sharpest proof of the same point: one machine run twice                                  |

## By entry ordering

| Answer                                    | Systems                                                         | Mechanism                                                                                                         |
| ----------------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| One sequence, raw bytes                   | [NAR][nar]                                                      | `std::string` `<`; the parser rejects `name <= prevName`                                                          |
| One sequence, `/` appended to directories | [git][git], [Nix `git-hashing`][nixgit], [SWH][swh], [bup][bup] | `base_name_compare` substitutes `/` for a directory name's terminating NUL — **four independent implementations** |
| Two arrays, raw bytes                     | [OSTree][ostree]                                                | files and directories sorted separately by `strcmp`                                                               |
| Three arrays, raw bytes                   | [REAPI][reapi], [Snix][castore]                                 | files, directories and symlinks each sorted by UTF-8 bytes                                                        |
| A privileged prefix                       | [JAR, via `strip-nondeterminism`][repro]                        | a comparator forcing `META-INF/` first                                                                            |
| Workload-derived                          | [eStargz][estargz]                                              | a prefetch plan from a profiling run; `.prefetch.landmark` marks the boundary                                     |
| Versioned in the data                     | [Venti's `vac`][venti]                                          | a known-wrong comparator retired by minting a new block magic                                                     |
| None                                      | [Tahoe][tahoe], [unixfs][ipfs]                                  | children are never sorted                                                                                         |
| Unspecified                               | [OCI][oci]                                                      | whatever the producer's tar emitted                                                                               |

## By metadata floor

| Floor                                                               | Systems                                                  |
| ------------------------------------------------------------------- | -------------------------------------------------------- |
| None — bytes or blocks only                                         | [Bao][bao], [Venti][venti], [dm-verity][apk]             |
| One executable bit                                                  | [NAR][nar], [Nix `git-hashing`][nixgit], [Snix][castore] |
| Path + revision id + one flag                                       | [Mercurial][hg]                                          |
| Five modes, incl. symlink and submodule                             | [git][git], [SWH][swh]                                   |
| Executable bit + open key/value properties (incl. optional `mtime`) | [REAPI][reapi]                                           |
| uid, gid, mode, xattrs — inside the content hash                    | [OSTree][ostree]                                         |
| Negotiable by feature flag                                          | [casync][casync]                                         |
| Full POSIX, including timestamps                                    | [OCI][oci], [composefs][cfs]                             |

## By partial verification

| Granularity                                 | Systems                                                                                              |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| None — all or nothing                       | [NAR][nar], [Mercurial][hg] (flat), [OCI][oci]                                                       |
| Per object / per directory                  | [git][git], [Nix `git-hashing`][nixgit], [OSTree][ostree], [REAPI][reapi], [SWH][swh], [bup][bup]    |
| Per chunk, via an **index** (depth-2 trust) | [eStargz / SOCI][estargz], [casync][casync]                                                          |
| Per chunk, via a **tree** (`O(log n)`)      | [Bao][bao], [REAPI `SHA256TREE`][reapi], [fs-verity][cfs], [dm-verity / APK v4][apk], [Tahoe][tahoe] |
| Reserved but unimplemented                  | [Snix][castore] — `StatBlobResponse.bao` is `// still todo`                                          |

---

## Milestones

| Year       | Event                                                                                                           |
| ---------- | --------------------------------------------------------------------------------------------------------------- | ---------- | ------ | ------------- | ----------- |
| 1980       | Merkle publishes hash trees (IEEE S&P) — cited by [Venti][venti] as its ancestor                                |
| 1998       | Stanford Archival Vault: a write-once object log, with "no way to share data between objects"                   |
| 2000       | SFSRO (OSDI): SHA-1 blocks "applied recursively"                                                                |
| 2001-10    | LBFS (SOSP): content-defined chunking                                                                           |
| 2002-01    | **[Venti][venti]** (FAST '02): a block-level content-addressed store; directories are files of `VtEntry` scores |
| 2003       | NAR appears in the Nix tree — `archive.cc`'s history begins 2003-11-18                                          |
| 2005-04    | Git's object model ships (first commit 2005-04-07)                                                              |
| 2011-10    | [OSTree][ostree] begins — git's model plus uid/gid/mode/xattrs, minus timestamps                                |
| 2018–2019  | [REAPI][reapi] v2 stabilizes the `Directory`/`Digest` canonical form                                            |
| 2019-10    | Sapling's [retrospective][hg] states the `O(                                                                    | repo files | )`→`O( | changed files | )` argument |
| 2020       | BLAKE3 published — a tree hash by construction, making verified streaming practical                             |
| 2021-04    | SWHID v1.6 — SHA-1 welded into the identifier grammar                                                           |
| 2022-05    | Nix's [git-hashing][nixgit] implementation lands — approximate                                                  |
| 2023-03-14 | [REAPI][reapi] adds `SHA256TREE`, "a version of SHA-256 that supports chunking" (PR #235)                       |
| 2024–2025  | [iroh][bao] settles on 16 KiB chunk groups; [Snix][castore] ships BLAKE3 identity with NAR at the boundary      |

> [!NOTE]
> Dates come from the repositories' own histories where a local clone or forge
> API was available, and from cited papers otherwise. Git-history dates record
> when an implementation _appeared_, which may postdate a design; entries
> marked approximate are exactly that.

---

## Suggested reading paths

**"I want the findings, not the survey."** → [Synthesis &
recommendations][rec] — in particular [axis 2][axis2] (no single canonical
order), [axis 4][axis4] (chunk trees are not exotic), and the two
[contradictions][contra] this survey produced against earlier decisions.

**"I'm implementing the content-addressing layer."** → [concepts][concepts] →
[NAR][nar] → [git objects][git] → [Nix `git-hashing`][nixgit] →
**[Snix `castore`][castore]** (a production system that made the same
architectural choice, and one different one) → [recommendations][rec].

**"I'm designing the scheme seam."** → [the falsification gate][gate], then
[REAPI][reapi] and [Bao][bao], which stress opposite ends of it.

**"I care about incremental rebuilds."** → [git `cache-tree`][cachetree] (the
mechanism, and racy-git) → [build input caches][caches] (the same shape with
the opposite failure mode).

**"I care about metadata fidelity."** → [OSTree][ostree] → [composefs +
fs-verity][cfs] → [axis 1][axis1].

**"I want to know why tar keeps failing."** → [OCI layers][oci] →
[reproducible archives][repro] → [NAR's rationale][nar].

---

## Sources

Every GitHub citation pins a 40-character commit SHA; non-GitHub forges are
pinned by commit where the forge supports it. Verified against local clones or
forge APIs:

- **Nix** — `NixOS/nix` at `1d8bdc1ee63246b591a8d77d0d481485cd09d438`
- **Git** — `git/git` at `f78ce2f7b6df702f93d40b85d6bda92a3f65da79`
- **Linux** — `torvalds/linux` at `e43ffb69e0438cddd72aaa30898b4dc446f664f8`
- **OSTree** — `ostreedev/ostree` at `1d5a312a3189b0fbd70fe6769aadb19a366fedb2`
- **Bazel REAPI** — `bazelbuild/remote-apis` at `76ddd98e1f92c0e2e71d0d3aa6906eca31754c03`
- **iroh blobs** — `n0-computer/iroh-blobs` at `e82cbdcbdac9a78033174aad55e3199b2cf4c0dc`
- **Sapling** — `facebook/sapling` at `87b7db94b0a7fc5186b472f0ee8d01fd5a2036a2`
- **OCI image-spec** — `opencontainers/image-spec` at `af26a05fba5ee648512f4ea3c9fda1fcc1b6d6dc`
- **casync** — `systemd/casync` at `b4b7e5606f785572b78a43626a27a45fe3df2fbd`
- **Snix** — `snix/snix` at `86a6e6ef8c1c43d015b09f10051de78b2cae548b` (Forgejo, `git.snix.dev`)
- **`strip-nondeterminism`** — salsa.debian.org at `904281367bd7fbc34a0831a28dd40457b6753c1c`

Related in-repo trees: [Fileset & File-Selection Query Languages][fsl] (which
files to name), [iroh][iroh] (the peer-to-peer side of Bao), and
[Monorepo Tooling][monorepo] (what consumes a build-input digest).

<!-- References -->

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
[rec]: ./recommendations.md
[axis1]: ./recommendations.md#axis-1--what-is-in-the-identity
[axis2]: ./recommendations.md#axis-2--entry-ordering
[axis3]: ./recommendations.md#axis-3--serial-versus-merkle
[axis4]: ./recommendations.md#axis-4--the-level-2-surprise
[idx-tree]: ./concepts.md#index-versus-tree
[disagree]: ./recommendations.md#what-it-does-not-agree-on
[gate]: ./recommendations.md#the-falsification-gate
[contra]: ./recommendations.md#what-this-survey-contradicted
[fsl]: ../fileset-languages/index.md
[iroh]: ../iroh/index.md
[monorepo]: ../monorepo-tooling/index.md
[bp]: ../../../libs/build-primitives/src/sparkles/build_primitives/gitignore.d
[nixspec]: ../../specs/nix/SPEC.md
