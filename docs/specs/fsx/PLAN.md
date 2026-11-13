# `fsx` — Delivery Plan

The order in which the [specification](./SPEC.md) is delivered. Each
milestone is a set of commits that leave the tree green; its acceptance is
the evidence its rows in [testing](./testing.md) name.

| Milestone | Delivers                                                                                                      | Requirements                                                      | Acceptance                                                                                            |
| --------- | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| M1        | `sparkles:fileset-tools`: the explorer's resolving, members, ids, Stats report and copy, moved out of the app | `XA6`                                                             | the explorer's tests pass over the library; `dub describe :fileset-tools` names no UI package         |
| M2        | `apps/fsx` with `cp` over local sources, the filter options, verification and the busybox names               | `XA1`–`XA5`, `XS1`, `XS2`, `XC1`–`XC7`, `XV1`, `XV2`, `XV4`–`XV6` | the `XA`, `XC` and `XV` tests over local fixtures; a verified copy of this repository's tracked files |
| M3        | `ls`                                                                                                          | `XL1`–`XL4`                                                       | the `XL` tests                                                                                        |
| M4        | The bridge's receive half and the iroh source: metadata first, the selection alone, verified streaming        | `XS1`, `XS3`, `XS4`, `XV3`, `XR1`–`XR6`                           | the `XR` tests against the repository's own provider; a copy from `sendme send`                       |
| M5        | `diff`, in the `full` configuration                                                                           | `XD1`–`XD3`                                                       | the `XD` tests; a local tree against a ticket with no content fetched                                 |
| M6        | `package.nix` in nixpkgs' style                                                                               | `XP1`–`XP3`                                                       | `callPackage` against a nixpkgs checkout builds each option combination; the closure is recorded      |
| M7        | macOS and Windows                                                                                             | `XP4`                                                             | the test suite on the owner's macOS machine and on Windows; `pathOf` on Windows                       |

M4 starts with a spike that answers one question: can the bridge read a
collection's names without any file, and stream a chosen child's verified
bytes to the caller, against the pinned `sendme`'s provider? The decision
criterion is a listing whose names and digests are the files', read in
under 4 KiB, and one child's bytes equal to its file, with the provider
reporting no payload beyond it and the names. It answered yes
(`iroh_send.XR.receiveSpike`), once the size proofs first planned were
dropped ([XO13](./decisions.md#xo13-no-sizes-before-the-filter-accepted)).
A negative answer would have reopened [XO9](./decisions.md#xo9-an-iroh-source-filters-before-it-downloads-accepted).

## Progress

M1–M6 are delivered on Linux, with the evidence [testing](./testing.md)
names; M7 on macOS (arm64). On Windows the code cross-compiles and has not
run: the next step is a run on a Windows host, then adding `fileset-tools`
and `fsx` to `ci/test-windows.sh`'s allowlist, and a Windows build of the
iroh bridge with a `LoadLibraryW` path in its loader.
