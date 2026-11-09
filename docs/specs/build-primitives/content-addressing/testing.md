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
`a/b/d/y ∪ q` and nothing.

## Evidence ledger

Evidence is from Linux x86_64, with DMD and LDC, against Snix at revision
`c27950ab360b92bbb8f2ca246efd0ed895ce1e58`, Nix 2.32.8 and git 2.51.2. A
requirement the ledger does not list is unverified.

| Requirements   | State                   | Evidence                                                                                                                                                                                                                                                  | Gap                                                                                     |
| -------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `CAM1`         | partial                 | NAR with start roots beneath the root equals `nix-store --dump` of the tree holding only the members (`content_addressing.nar.startRoots`); castore over the same filesets equals the tee's (`content_addressing.tee.startRoots`)                         | castore and git with start roots, against their own oracles                             |
| `CAM2`         | verified (Linux x86_64) | git's id equals `git write-tree` on every fixture tree, and the bytewise control differs on more than a quarter of them (`content_addressing.git.writeTree`)                                                                                              | —                                                                                       |
| `CAM3`, `CAM4` | unverified              | —                                                                                                                                                                                                                                                         | a driver that changes a file's size mid-read, and one that reports an entry unreadable  |
| `CAM5`         | unverified              | the encoders are `@nogc` (`content_addressing.castore.encoding`, `content_addressing.git.writeTree`), which does not prove it                                                                                                                             | the allocation instrumentation around a content-addressing resolution                   |
| `CAC1`–`CAC5`  | verified (Linux x86_64) | the textual id equals `snix-castore ingest`'s on every fixture tree (`content_addressing.castore.snix`); a hand-encoded message, the empty directory's id and nested sizes (`content_addressing.castore.encoding`)                                        | the test skips without `$SPARKLES_SNIX_CASTORE`, which the shells set on Linux only     |
| `CAN1`, `CAN2` | verified (Linux x86_64) | digest and length equal those of `nix-store --dump` on every fixture tree (`content_addressing.nar.dump`)                                                                                                                                                 | Nix is the host's, not pinned by the flake; the test skips without it                   |
| `CAN3`         | verified (Linux x86_64) | start roots beneath the root, ordered `a/b` before `a-c`, and the empty fileset, against `nix-store --dump` (`content_addressing.nar.startRoots`)                                                                                                         | as `CAN1`                                                                               |
| `CAN4`         | unverified              | —                                                                                                                                                                                                                                                         | a comparison with `nix hash path`'s SRI output                                          |
| `CAG1`, `CAG2` | verified (Linux x86_64) | SHA-1 and SHA-256 ids equal `git write-tree`'s on every fixture tree, empty and hollow directories and the empty tree included (`content_addressing.git.writeTree`); the encoder's empty tree is git's well-known id (`content_addressing.git.emptyTree`) | git is the host's, not pinned by the flake                                              |
| `CAT1`, `CAT3` | verified (Linux x86_64) | a tee of castore and git equals castore, git and NAR alone on every fixture tree (`content_addressing.tee.parts`); `CastoreNar` equals castore and NAR alone on four start-root filesets (`content_addressing.tee.startRoots`)                            | —                                                                                       |
| `CAT2`         | partial                 | a counting leaf in a tee hears each file once and each byte once (`content_addressing.tee.readsOnce`)                                                                                                                                                     | the count is of what the leaf hears, not of opens: a driver that counts opens and reads |
| `CAO1`, `CAO2` | not started             | the supplied tree's layout is open ([C2](./decisions.md#c2-the-outboard-s-layout-open))                                                                                                                                                                   | everything                                                                              |
