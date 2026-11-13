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

M4 starts with a spike that answers one question: can the bridge request a
collection's metadata and one last-chunk range per file in a single
request, and stream a chosen child's verified bytes to the caller, against
`sendme send` of the pinned version? The decision criterion is a received
metadata blob equal to the D collection's, sizes equal to the files', and
one child's bytes equal to its file, with the provider reporting no payload
beyond them. A negative answer reopens [XO9](./decisions.md#xo9-an-iroh-source-filters-before-it-downloads-accepted).
