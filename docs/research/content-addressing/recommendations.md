# Synthesis & recommendations

The capstone: the axis table this survey exists to produce, the two subjects
run through it as a falsification gate, and what
[`sparkles:build-primitives`][bp] should adopt.

**Last reviewed:** September 21, 2026

---

## The six axes

| Axis                        | [NAR][nar]                                  | [git][git]                   | [Nix `git-hashing`][nixgit]  | [REAPI][reapi]                               | [OSTree][ostree]          | [Bao][bao]           |
| --------------------------- | ------------------------------------------- | ---------------------------- | ---------------------------- | -------------------------------------------- | ------------------------- | -------------------- |
| **1. Node model**           | regular+exec, dir, symlink                  | 5 modes (incl. gitlink)      | Nix's triple, **partially**  | file+exec, dir, symlink, + properties        | + uid/gid/mode/xattrs     | none — bytes         |
| **2. Entry ordering**       | byte-wise, one sequence                     | byte-wise **+ implicit `/`** | git's, via `/`-suffixed keys | byte-wise, **three arrays**                  | byte-wise, **two arrays** | n/a                  |
| **3. Level-1 composition**  | **serial**                                  | Merkle DAG                   | Merkle DAG                   | Merkle DAG (+ flattened `Tree`)              | Merkle DAG (+ `dirmeta`)  | **absent**           |
| **4. Level-2 granularity**  | whole blob, inline                          | whole blob                   | whole blob                   | whole blob **or `SHA256TREE`**               | whole blob + header       | **chunk tree**       |
| **5. Digest**               | SHA-256 over the stream; `NarSize` separate | SHA-1 / SHA-256              | SHA-1 / SHA-256              | `{hash, size_bytes}`, 7 functions            | SHA-256                   | BLAKE3, 32 raw bytes |
| **6. Partial verification** | **none**                                    | per object                   | per object                   | per `Directory`, per chunk with `SHA256TREE` | per object                | **per 16 KiB group** |

### Axis 1 — what is in the identity

The field agrees on the exclusion and disagrees on the floor. Everyone drops
timestamps — [Nix][nar] because they "cause FSOs that Nix should consider equal
to hash to different values on different machines", [OSTree][ostree] because
hardlinked checkouts must compare as up to date. Only [REAPI][reapi] can carry
an `mtime` at all, and only as an optional, server-declared node property.

Above that floor the spread is the whole design space: git adds a submodule
mode nobody else has, OSTree pulls ownership and xattrs _inside_ the file hash
(and pays for it in lost dedup), REAPI makes metadata an open key-value list
(and pays in cross-server ambiguity).

### Axis 2 — entry ordering

**Four distinct answers, and no two are interchangeable.** This is the
survey's most consequential finding, because a single "canonical order"
primitive is the natural thing to write and would be wrong.

| Answer                                    | Systems                                 | Mechanism                                                                       |
| ----------------------------------------- | --------------------------------------- | ------------------------------------------------------------------------------- |
| One sequence, raw bytes                   | [NAR][nar]                              | `std::string` `<`; reader rejects `name <= prevName`                            |
| One sequence, `/` appended to directories | [git][git], [Nix `git-hashing`][nixgit] | `base_name_compare` substitutes `/` for the terminating NUL of a directory name |
| Two arrays, raw bytes                     | [OSTree][ostree]                        | files and directories sorted separately by `strcmp`                             |
| Three arrays, raw bytes                   | [REAPI][reapi]                          | files, directories and symlinks each sorted by UTF-8 bytes                      |

The first two differ on real inputs. Given a directory `a` and a file `a.b`,
`.` is `0x2E` and `/` is `0x2F`, so git orders `a.b` before `a` while a
byte-wise sort orders `a` first — reproducible in three lines against real git
(see [the git deep-dive][git-order]). The partitioned answers (OSTree, REAPI)
make the question _structurally_ unaskable: a file and a directory never
compare.

Git pays a measurable price for its choice. Because the implicit slash can
separate two spellings of one name, duplicate detection needs a stack rather
than an adjacent-pair check — `fsck.c` documents the `foo` / `foo.bar` /
`foo.bar/` / `foo/` case explicitly — where NAR's `name <= prevName` suffices.

### Axis 3 — serial versus Merkle

One subject is serial, four are Merkle, one has no level 1. Everything a build
system wants — subtree caching, O(depth) rehash after a one-file edit,
independent verification of a fragment, parallel hashing across files — follows
from the Merkle side of that line, and none of it is recoverable on the serial
side. NAR's compensation is that it is trivially streamable in constant memory.

### Axis 4 — the level-2 surprise

The expectation going in was that intra-file chunk trees were a peer-to-peer
concern. They are not. [REAPI's `SHA256TREE`][reapi] is a chunked Merkle hash
in a _build_ protocol, adopted for the same two reasons [Bao][bao] exists —
chunk-level integrity, and parallelism a serial SHA-256 cannot offer — with an
explicit note that it "can be computed more efficiently than plain SHA-256
hashes by using generic SIMD extensions".

The design consequence is concrete: **any seam that hands a scheme a
whole-file digest, or a fixed-size push stream of content, forecloses this
entire class.** A scheme must be able to read its own bytes, in its own order,
at its own concurrency.

### Axis 5 — what travels with a digest

[REAPI][reapi] puts `size_bytes` inside `Digest`; [iroh][bao] carries a claimed
size in the wire header and verifies that the final validated leaf ends exactly
there. Both arrived at the same guard from opposite directions: a length beside
the hash catches truncation and inflation without hashing. Nix keeps `NarSize`
beside `NarHash` in `.narinfo` for the same reason. git and OSTree do not, and
have no equivalent.

Algorithm agility is real only in REAPI (seven functions, negotiated) and the
IPFS family (multihash tagging). git makes it a repository-wide property; Nix,
OSTree and iroh fix it.

### Axis 6 — partial verification

Falls out of axes 3 and 4 and needs no separate argument: object granularity
from a Merkle level 1, chunk granularity from a Merkle level 2, nothing from a
serial scheme.

---

## What the field agrees on

1. **Timestamps are not identity.** Unanimous, with two independently-derived
   rationales.
2. **Canonical form must be specified and checked**, not assumed. NAR rejects
   unsorted input at the parser; git names each violation as an `fsck` code;
   REAPI defines "canonical form" as a normative term.
3. **Symlinks are values, not links.** Every subject stores the target string
   and refuses to follow it.
4. **Byte-wise comparison, never locale or case folding** — in all four
   ordering answers.

## What it does not agree on

1. **Ordering** (four answers, axis 2).
2. **The metadata floor** (one bit, five modes, or uid/gid/mode/xattrs).
3. **Case collisions** — three distinct answers, none of them detection at
   hashing time:

   | System         | Behaviour                                                                                                                 |
   | -------------- | ------------------------------------------------------------------------------------------------------------------------- |
   | [NAR][nar]     | name mangling: `~nix~case~hack~` + counter on restore, stripped on dump; throws only when unhacking collides              |
   | [git][git]     | permitted silently; fails at checkout on a case-insensitive filesystem                                                    |
   | [REAPI][reapi] | "legal to call the API with […] both `Foo` and `foo`, but the Action may be rejected by the remote system upon execution" |

   All three push the failure away from its cause — into a restore, a checkout,
   or a remote worker.

---

## The falsification gate

The seam being designed declares, per scheme: a **required entry ordering**, a
**metadata mask**, a **traversal mode** (pre-order stream or post-order fold),
and **no content requests at all** — schemes own their own byte I/O. Two
subjects were run through it before any of it was written. Both fit; both
found something.

### REAPI through the seam

| Seam feature   | REAPI needs                                                 | Verdict                                                                                                               |
| -------------- | ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Traversal mode | post-order fold (a `Directory` digest needs its children's) | ✅ fold                                                                                                               |
| Ordering       | byte-wise, partitioned into three arrays                    | ✅ — sort once byte-wise, partition by kind; partitioning a byte-wise-sorted list yields three byte-wise-sorted lists |
| Metadata       | exec bit … **and an optional `mtime`**                      | ⚠️ **finding 1**                                                                                                      |
| Content        | whole-blob digest, or `SHA256TREE` chunk tree               | ✅ — scheme-owned I/O covers both                                                                                     |
| Digest         | hash + size                                                 | ✅ — size is a scheme concern                                                                                         |

> **Finding 1 — the metadata mask must admit `mtime`.** The node model
> deliberately excludes timestamps from _identity_, and should. But REAPI can
> attach one as a node property, and a scheme cannot synthesize what the walk
> never requested. Since the `mtime` arrives in the same `statx` already issued
> for the executable bit, admitting it to the **mask** costs nothing — and
> keeping it out of the **identity** remains a separate, unchanged rule.

### Bao through the seam

| Seam feature | Bao needs                                              | Verdict                                                              |
| ------------ | ------------------------------------------------------ | -------------------------------------------------------------------- |
| Level 1      | none — a blob is the root                              | ✅ — levels are independent, so a level-2-only scheme is expressible |
| Ordering     | n/a                                                    | ✅ `none`                                                            |
| Content      | parallel reads of arbitrary aligned ranges of one file | ✅ — the scheme opens its own `FsoRef`                               |
| Concurrency  | intra-file parallelism                                 | ✅ — bounded by the shared admission budget                          |

Bao is the subject that justifies two earlier decisions in retrospect: content
_must not_ be pushed to a scheme (a 100 GiB file's chunk tree is the thing that
parallelizes, and an in-order span feed serializes it), and level 1 and level 2
_must_ be independent (Bao has no level 1 at all).

### OSTree through the seam

Run as a third check, because it is the metadata-richness outlier:

> **Finding 2 — the request vocabulary needs an extension point.** OSTree's
> identity includes extended attributes, which need `listxattr`/`getxattr` —
> outside the `readDir`/`stat`/`readlink`/`readFile` set. The vocabulary should
> therefore be **declared open**, with a scheme's unsatisfiable request a
> typed error rather than a silent omission. Xattrs stay unimplemented in v1;
> the point is that adding them must not be a breaking change to the seam.

### Findings 3 — traversal mode has a performance consequence

Pre-order streaming ([NAR][nar]) cannot use the walk's parallelism: the stream
is serial and so is the hash over it. Post-order folding (git, REAPI, OSTree)
uses it fully. The seam supports both, but the choice is not merely a shape —
it determines whether a scheme scales with cores at all.

---

## Recommendations for `sparkles:build-primitives`

1. **Internal identity: a git-shaped Merkle tree hash.** It is the only option
   that yields subtree values (incremental rehash, cross-run caching, parallel
   hashing) _and_ comes with two independent oracles — `git write-tree` /
   `git hash-object`, plus Nix's own second implementation in
   [`git.cc`][nixgit]. Accept its documented partiality: a bare executable file
   or bare symlink at the root is an **error**, exactly as
   [Nix does][nixgit-partial].
2. **`NarHash` / `NarSize` computed serially, on demand, at the Nix boundary
   only.** The serial cost is irrelevant there because the bytes are being
   streamed anyway.
3. **Name the two orderings separately** — `narOrder` and `gitTreeOrder` — and
   pin the difference with the `a` versus `a.b` fixture. Do not write a
   `canonicalOrder`. Implement `gitTreeOrder` with the `/`-suffix trick that
   git, Nix and irmin all converged on.
4. **Admit `none` as an ordering**, for consumers that rank rather than hash,
   and let the ordering choice select the emission shape (streamed entries
   versus a buffered sorted batch). Exclude `none` at compile time for fold
   schemes: `readdir` order is nondeterministic, and a digest over it would be
   silently wrong.
5. **Identity is byte-exact.** No case folding, no Unicode normalization — the
   unanimous position of the field, and the only one that interoperates.
6. **Detect case and normalization collisions at hash time and return an
   `Expected` error naming both entries.** This is a _fourth_ answer, and
   deliberately so: NAR's mangling, git's silence and REAPI's deferral all move
   the failure away from its cause, which is defensible for a VCS or a remote
   execution API and not for a build tool whose job is to say whether inputs
   changed.
7. **Carry the length beside the digest.** Two subjects independently derived
   this guard; it is nearly free.
8. **Keep content out of the fileset machine entirely** (findings above), and
   keep the metadata mask and request vocabulary **open** (findings 1 and 2).
9. **Copy NAR's bounds.** `narMaxDepth` 64, `narMaxTag` 32, `narMaxName` 255 —
   a `@nogc` implementation needs exactly this kind of a priori limit, and
   Nix's stated reason (bounding stack usage on a coroutine stack) applies
   directly to a sans-IO machine.

## Out of scope, and why

- **Store paths, `.narinfo`, signatures, compression** — the binary-cache
  client layer. [`sparkles:nix`][nix-lib] binds `libnixstore-c` and can compute
  these for real; reimplementing them buys nothing.
- **Content-defined chunking** (FastCDC and relatives) — a level-2 boundary
  policy, not an addressing scheme. Named where a subject uses one.
- **Typed-data Merkleization** (Ethereum SSZ and relatives) — addresses
  consensus objects, not file system objects. Different domain.

<!-- References -->

[nar]: ./nar.md
[git]: ./git-objects.md
[git-order]: ./git-objects.md#dimension-2--canonical-form-and-ordering
[nixgit]: ./nix-git-hashing.md
[nixgit-partial]: ./nix-git-hashing.md#design-philosophy
[reapi]: ./reapi.md
[ostree]: ./ostree.md
[bao]: ./bao-blake3.md
[bp]: ../../../libs/build-primitives/src/sparkles/build_primitives/gitignore.d
[nix-lib]: ../../specs/nix/SPEC.md
