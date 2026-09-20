# Content Addressing of File System Objects

A primary-source survey of how six systems turn a directory tree into a digest
— Nix's serial [NAR][nar], [git's][git] Merkle DAG, the
[bridge between them][nixgit] inside Nix itself, [Bazel's REAPI][reapi],
[OSTree][ostree], and [Bao/BLAKE3][bao]'s tree _inside_ a single file. The
evidence base for the content-addressing layer of
[`sparkles:build-primitives`][bp], and the falsification gate for the scheme
seam that layer is being designed around.

This survey answers seven questions:

1. **Serial serialization or Merkle DAG?** Five of six are Merkle, and
   everything a build system wants — subtree caching, `O(depth)` rehash,
   independent verification, parallel hashing — lives on that side of the line.
   See [axis 3][axis3].
2. **Is there one canonical entry order?** **No — there are four**, and two of
   them disagree on inputs as ordinary as a directory `a` beside a file `a.b`.
   See [axis 2][axis2] and the [worked case][git-order].
3. **What belongs inside an identity?** Timestamps: unanimously not. Everything
   above that floor: no agreement at all. See [axis 1][axis1].
4. **Are intra-file chunk trees a peer-to-peer curiosity?** No —
   [REAPI's `SHA256TREE`][reapi] put one in a build protocol in 2023, for the
   same two reasons [Bao][bao] exists. See [axis 4][axis4].
5. **How does the field handle case collisions?** Three distinct ways, and
   **none of them detects the collision at hashing time**. See
   [the disagreements][disagree].
6. **Can one seam express all of them?** Yes — and running
   [REAPI][gate-reapi], [Bao][gate-bao] and [OSTree][gate-ostree] through it on
   paper produced three findings before any code was written.
7. **What should `sparkles:build-primitives` adopt?** See the
   [recommendations][rec].

**Last reviewed:** September 21, 2026

> [!NOTE]
> **Scope.** Six systems, six deep-dives, one synthesis. This tree is about
> turning a _tree of files_ into a _digest_. It is not about **selecting** the
> files — that is [Fileset & File-Selection Query Languages][fsl] — nor about
> the store, signature and cache layers above the digest, which
> [`sparkles:nix`][nixspec] reaches through `libnixstore-c` rather than
> reimplementing.
>
> Deliberately excluded, and named so they are not re-derived: **content-defined
> chunking** (FastCDC and relatives) is a level-2 boundary policy rather than an
> addressing scheme, and **typed-data Merkleization** (Ethereum SSZ) addresses
> consensus objects rather than file system objects. Deferred, noted not
> omitted: IPFS unixfs/DAG-PB beyond the sketch in [Bao][bao-unixfs], Docker/OCI
> image layer digests, and Perkeep.

---

## Master catalog

| Subject               | Ecosystem           | Level 1 (directory tree)           | Level 2 (file bytes)           | Entry ordering               | Digest                            | Link     |
| --------------------- | ------------------- | ---------------------------------- | ------------------------------ | ---------------------------- | --------------------------------- | -------- |
| **Nix Archive (NAR)** | Nix                 | serial serialization               | whole blob, inline             | byte-wise, one sequence      | SHA-256 over the stream           | [nar]    |
| **Git objects**       | Git                 | Merkle DAG                         | whole blob                     | byte-wise **+ implicit `/`** | SHA-1 / SHA-256                   | [git]    |
| **Nix `git-hashing`** | Nix (experimental)  | git trees, over Nix's FSO model    | git blobs                      | git's                        | SHA-1 / SHA-256                   | [nixgit] |
| **Bazel REAPI**       | Bazel, Buck2, Pants | Merkle DAG of protobuf `Directory` | whole blob **or `SHA256TREE`** | byte-wise, three arrays      | `{hash, size_bytes}`, 7 functions | [reapi]  |
| **OSTree**            | Linux OS images     | Merkle DAG (`dirtree` + `dirmeta`) | whole blob + header            | byte-wise, two arrays        | SHA-256                           | [ostree] |
| **Bao / BLAKE3**      | iroh, `bao-tree`    | **none**                           | **Merkle chunk tree**          | n/a                          | BLAKE3, 32 raw bytes              | [bao]    |

Shared vocabulary — file system object, the level-1/level-2 split, canonical
form, partial verification — is defined once in [concepts][concepts].

## By level-1 composition

| Composition          | Systems                                                                   | Consequence                                                                                   |
| -------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Serial serialization | [NAR][nar]                                                                | No subtree values: no caching, no incremental rehash, no parallelism, no partial verification |
| Merkle DAG           | [git][git], [Nix `git-hashing`][nixgit], [REAPI][reapi], [OSTree][ostree] | Subtree identity, `O(depth)` rehash, object-granular verification                             |
| None                 | [Bao][bao]                                                                | A level-2-only scheme — proof the two levels are independent, not nested                      |

## By entry ordering

| Answer                                    | Systems                                 | Mechanism                                                                  |
| ----------------------------------------- | --------------------------------------- | -------------------------------------------------------------------------- |
| One sequence, raw bytes                   | [NAR][nar]                              | `std::string` `<`; the parser rejects `name <= prevName`                   |
| One sequence, `/` appended to directories | [git][git], [Nix `git-hashing`][nixgit] | `base_name_compare` substitutes `/` for a directory name's terminating NUL |
| Two arrays, raw bytes                     | [OSTree][ostree]                        | files and directories sorted separately by `strcmp`                        |
| Three arrays, raw bytes                   | [REAPI][reapi]                          | files, directories and symlinks each sorted by UTF-8 bytes                 |

## By metadata floor

| Floor                                                               | Systems                                 |
| ------------------------------------------------------------------- | --------------------------------------- |
| One executable bit                                                  | [NAR][nar], [Nix `git-hashing`][nixgit] |
| Five modes, incl. symlink and submodule                             | [git][git]                              |
| Executable bit + open key/value properties (incl. optional `mtime`) | [REAPI][reapi]                          |
| uid, gid, mode, xattrs — inside the content hash                    | [OSTree][ostree]                        |
| None — bytes only                                                   | [Bao][bao]                              |

Timestamps are excluded from identity by every subject but [REAPI][reapi],
where they are optional and server-declared.

## By partial verification

| Granularity                   | Systems                                                                   |
| ----------------------------- | ------------------------------------------------------------------------- |
| None — all or nothing         | [NAR][nar]                                                                |
| Per object / per directory    | [git][git], [Nix `git-hashing`][nixgit], [OSTree][ostree], [REAPI][reapi] |
| Per chunk group inside a file | [Bao][bao] (16 KiB), [REAPI][reapi] with `SHA256TREE`                     |

---

## Milestones

| Year       | Event                                                                                                               |
| ---------- | ------------------------------------------------------------------------------------------------------------------- |
| 2003       | NAR appears in the Nix tree — `archive.cc`'s history begins 2003-11-18                                              |
| 2005       | Git's object model ships (first commit 2005-04-07): content-addressed blobs and trees, SHA-1                        |
| 2011       | OSTree begins (first commit 2011-10-09) — git's model plus uid/gid/mode/xattrs, minus timestamps                    |
| 2018–2019  | Bazel Remote Execution API v2 stabilizes the `Directory`/`Digest` canonical form                                    |
| 2020       | BLAKE3 published — a tree hash by construction, making verified streaming practical                                 |
| 2022       | Nix's git-hashing implementation lands (`src/libutil/git.cc`, first appears 2022-05-04) — approximate               |
| 2023-03-14 | REAPI adds `SHA256TREE`, "a version of SHA-256 that supports chunking" (PR #235) — a chunk tree in a build protocol |
| 2024–2025  | iroh's `iroh-blobs` settles on 16 KiB chunk groups and the data/outboard split                                      |

> [!NOTE]
> Dates come from the repositories' own histories where a local clone was
> available (Nix, git, OSTree, remote-apis) and are marked approximate
> otherwise. Git-history dates record when an implementation _appeared_, which
> may postdate a design.

---

## Suggested reading paths

**"I want the finding, not the survey."** → [Synthesis & recommendations][rec],
specifically [axis 2][axis2] (four orderings) and [axis 4][axis4] (chunk trees
are not exotic).

**"I'm implementing the content-addressing layer."** → [concepts][concepts] →
[NAR][nar] → [git objects][git] → [Nix `git-hashing`][nixgit] (the bridge, and
the closest precedent for the chosen design) → [recommendations][rec].

**"I'm designing the scheme seam."** → [the falsification gate][gate] first,
then [REAPI][reapi] and [Bao][bao], which stress opposite ends of it.

**"I care about metadata fidelity."** → [OSTree][ostree], then
[axis 1][axis1].

---

## Sources

Every GitHub citation pins a 40-character commit SHA. The clones read for this
survey:

- **Nix** — `NixOS/nix` at `1d8bdc1ee63246b591a8d77d0d481485cd09d438`
- **Git** — `git/git` at `f78ce2f7b6df702f93d40b85d6bda92a3f65da79`
- **OSTree** — `ostreedev/ostree` at `1d5a312a3189b0fbd70fe6769aadb19a366fedb2`
- **Bazel REAPI** — `bazelbuild/remote-apis` at `76ddd98e1f92c0e2e71d0d3aa6906eca31754c03`
- **iroh blobs** — `n0-computer/iroh-blobs` at `e82cbdcbdac9a78033174aad55e3199b2cf4c0dc`

Related in-repo trees: [Fileset & File-Selection Query Languages][fsl] (which
files to name), [iroh][iroh] (the peer-to-peer side of Bao), and
[Monorepo Tooling][monorepo] (what consumes a build-input digest).

<!-- References -->

[concepts]: ./concepts.md
[nar]: ./nar.md
[git]: ./git-objects.md
[git-order]: ./git-objects.md#dimension-2--canonical-form-and-ordering
[nixgit]: ./nix-git-hashing.md
[reapi]: ./reapi.md
[ostree]: ./ostree.md
[bao]: ./bao-blake3.md
[bao-unixfs]: ./bao-blake3.md#the-sibling-ipfs-unixfs
[rec]: ./recommendations.md
[axis1]: ./recommendations.md#axis-1--what-is-in-the-identity
[axis2]: ./recommendations.md#axis-2--entry-ordering
[axis3]: ./recommendations.md#axis-3--serial-versus-merkle
[axis4]: ./recommendations.md#axis-4--the-level-2-surprise
[disagree]: ./recommendations.md#what-it-does-not-agree-on
[gate]: ./recommendations.md#the-falsification-gate
[gate-reapi]: ./recommendations.md#reapi-through-the-seam
[gate-bao]: ./recommendations.md#bao-through-the-seam
[gate-ostree]: ./recommendations.md#ostree-through-the-seam
[fsl]: ../fileset-languages/index.md
[iroh]: ../iroh/index.md
[monorepo]: ../monorepo-tooling/index.md
[bp]: ../../../libs/build-primitives/src/sparkles/build_primitives/gitignore.d
[nixspec]: ../../specs/nix/SPEC.md
