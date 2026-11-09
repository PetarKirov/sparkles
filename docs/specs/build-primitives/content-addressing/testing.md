---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-09
---

# Content addressing — Testing

_Companion to [SPEC.md](./SPEC.md): the oracles each requirement is checked
against, the trees they are checked on, and the evidence ledger._

## Oracles

Every format is checked against an implementation that shares no code with
ours. Each runs on a copy of the tree materialized on disk, while our scheme
runs over the in-memory driver, so the two also list the tree independently.

| Oracle                | Independence                                                    | Establishes                  | Where it comes from                                                                                                    |
| --------------------- | --------------------------------------------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `snix-castore ingest` | Snix's own implementation of its format, in Rust                | `CAC1`–`CAC5`                | the flake input `snix-src`, built by `packages.snix-castore`; the shells export it as `$SPARKLES_SNIX_CASTORE` (Linux) |
| `nix-store --dump`    | Nix's own serializer, which defines the format                  | `CAN1`–`CAN3`                | the host's Nix                                                                                                         |
| `git write-tree`      | git's own index and tree writer, after `git add -A -f`          | `CAG1`, `CAG2`, `CAM2`       | the host's git, in repositories made with `--object-format=sha1` and `sha256`                                          |
| A bytewise control    | the git encoding sorted by bytes: an oracle that must disagree  | that `CAM2`'s check can fail | `BytewiseGitTree`, in the test module                                                                                  |
| Each scheme alone     | the fold and the stream that a tee's parts are checked against  | `CAT1`                       | `CastoreScheme`, `GitTreeScheme` and `NarScheme`, each already checked against its own oracle                          |
| Hand-encoded messages | protobuf bytes written out by hand from the message definitions | `CAC2`, `CAC3`               | `content_addressing.castore.encoding`                                                                                  |

The bytewise control is how the ordering check is tested: on at least a
quarter of the trees, git's encoding over bytewise order differs from
`git write-tree`, so a scheme that ignored its declared order would fail.

A tee's parts are checked against the schemes alone, not against the
external oracles a second time. That is sound only because each scheme
alone is checked against its oracle on the same trees.

## Fixtures

`oracleTrees` in `content_addressing/testing.d` gives every oracle the same
trees:

- **hazard**: `a/x`, `a.b`, `a-b`, `a+`, `a0`, `ab/c`, where git's order puts
  the directory `a` after `a.b`, `a-b` and `a+` but before `a0`.
- **kinds**: nested directories, an empty directory, a directory holding only
  an empty directory, an executable file, a link into the tree and a link
  out of it.
- **case collision**: `A` and `a`, `B/x` and `b/x`.
- **no hazard** and the **empty tree**.
- The filesets fixture set.
- 200 random trees from seed 20 261 108, with links, executables and empty
  directories, each file holding text.

Start roots beneath the root are checked on one tree,
`a/b/x a/b/d/y a/c a-c/z q`, with the filesets `a/b/** ∪ a-c/**`, `a/c`,
`a/b/d/y ∪ /q` and nothing. Every pattern is anchored: an unanchored `q`
would hand over the directories searched for it
([C3](./decisions.md#c3-memberless-directories-in-an-id-proposed)).

## Evidence ledger

Evidence is from Linux x86_64, with DMD and LDC, against Snix at revision
`c27950ab360b92bbb8f2ca246efd0ed895ce1e58`, Nix 2.32.8 and git 2.51.2. A
requirement the ledger does not list is unverified.

| Requirements   | State                   | Evidence                                                                                                                                                                                                                                                                                                                                                                                                         | Gap                                                                                                                                                                                                                                  |
| -------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `CAM1`         | partial                 | with start roots beneath the root, castore equals `snix-castore ingest`, git equals `git write-tree` in SHA-1 and SHA-256 repositories, and NAR equals `nix-store --dump`, each of the tree holding only the members (`content_addressing.castore.startRoots`, `content_addressing.git.startRoots`, `content_addressing.nar.startRoots`); the tee equals the schemes alone (`content_addressing.tee.startRoots`) | an unanchored pattern hands over the memberless directories it searched, so castore and NAR depend on how the fileset is written ([C3](./decisions.md#c3-memberless-directories-in-an-id-proposed)); the cases use anchored patterns |
| `CAM2`         | verified (Linux x86_64) | git's id equals `git write-tree` on every fixture tree, and the bytewise control differs on more than a quarter of them (`content_addressing.git.writeTree`)                                                                                                                                                                                                                                                     | —                                                                                                                                                                                                                                    |
| `CAM3`         | verified (Linux x86_64) | a leaf that rewrites its file after the `stat` and before the first read, growing, shrinking or emptying it, fails castore, git and the tee of castore and NAR with `schemeFailed`; rewritten at the same size, the file is named by the bytes read (`content_addressing.merkle.CAM3.resized`)                                                                                                                   | NAR alone is checked only inside the tee, which reads through the same `streamFile`; the in-memory driver only                                                                                                                       |
| `CAM4`         | verified (Linux x86_64) | a mount the walk does not cross, and a file removed between its directory's listing and its `stat`, fail castore, git, NAR and the tee with `schemeFailed` (`content_addressing.merkle.CAM4.incomplete`)                                                                                                                                                                                                         | the in-memory driver only: a permission error on disk is not exercised                                                                                                                                                               |
| `CAM5`         | verified (Linux x86_64) | the wrapped libc allocator and the GC counter, around the scheme's own calls, count zero in a second resolution of a tree with a 300-entry directory and a 40 000-byte file, for castore, git, NAR and `CastoreNar`, where the first resolution counted some (`content_addressing.allocation.secondResolutionHasZeroCalls`, in the `allocation-audit` configuration)                                             | the resolution around the scheme is audited by the filesets contract, not here                                                                                                                                                       |
| `CAC1`–`CAC5`  | verified (Linux x86_64) | the textual id equals `snix-castore ingest`'s on every fixture tree (`content_addressing.castore.snix`); a hand-encoded message, the empty directory's id and nested sizes (`content_addressing.castore.encoding`)                                                                                                                                                                                               | the test skips without `$SPARKLES_SNIX_CASTORE`, which the shells set on Linux only                                                                                                                                                  |
| `CAN1`, `CAN2` | verified (Linux x86_64) | digest and length equal those of `nix-store --dump` on every fixture tree (`content_addressing.nar.dump`)                                                                                                                                                                                                                                                                                                        | Nix is the host's, not pinned by the flake; the test skips without it                                                                                                                                                                |
| `CAN3`         | verified (Linux x86_64) | start roots beneath the root, ordered `a/b` before `a-c`, and the empty fileset, against `nix-store --dump` (`content_addressing.nar.startRoots`)                                                                                                                                                                                                                                                                | as `CAN1`                                                                                                                                                                                                                            |
| `CAN4`         | verified (Linux x86_64) | `toSri` of the digest equals `nix hash path`'s output on the hand-written trees, the fixture set and 20 random trees (`content_addressing.nar.CAN4.sri`)                                                                                                                                                                                                                                                         | as `CAN1`                                                                                                                                                                                                                            |
| `CAG1`, `CAG2` | verified (Linux x86_64) | SHA-1 and SHA-256 ids equal `git write-tree`'s on every fixture tree, empty and hollow directories and the empty tree included (`content_addressing.git.writeTree`); the encoder's empty tree is git's well-known id (`content_addressing.git.emptyTree`)                                                                                                                                                        | git is the host's, not pinned by the flake                                                                                                                                                                                           |
| `CAT1`, `CAT3` | verified (Linux x86_64) | a tee of castore and git equals castore, git and NAR alone on every fixture tree (`content_addressing.tee.parts`); `CastoreNar` equals castore and NAR alone on four start-root filesets (`content_addressing.tee.startRoots`)                                                                                                                                                                                   | —                                                                                                                                                                                                                                    |
| `CAT2`         | verified (Linux x86_64) | a counting leaf in a tee hears each file once and each byte once (`content_addressing.tee.readsOnce`); at the backend, a tee of castore, git and NAR opens one entry per member file beyond the walk's own opens, and reads as often as one scheme alone, a 40 000-byte file included (`content_addressing.tee.opensOnce`)                                                                                       | the in-memory driver only                                                                                                                                                                                                            |
| `CAO1`, `CAO2` | not started             | the supplied tree's layout is open ([C2](./decisions.md#c2-the-outboard-s-layout-open))                                                                                                                                                                                                                                                                                                                          | everything                                                                                                                                                                                                                           |
