# `fsx` — Testing

How each requirement of the [specification](./SPEC.md) is checked, and what
has been. Fixtures are trees built in a fresh temporary directory with plain
file-system calls, never through the code under test.

## Oracles

- **Content ids.** The castore, NAR and git ids a copy is verified against
  are content addressing's, whose own oracles are Snix, Nix and git
  ([testing](../build-primitives/content-addressing/testing.md)); a copy's
  ids are also checked against `fileset-explorer stats --ids` over the same
  members, a separate caller of the same library.
- **Layouts and listings** are compared with trees and listings written out
  by hand for each fixture.
- **The iroh source** is checked against `sendme send` of the pinned version,
  a separate implementation of the provider, and against the repository's
  own provider, whose counters report the payload bytes it sent. A stand-in
  provider that corrupts a byte or a name supplies the hostile cases.
- **`fsdiff`** is checked against fixture pairs whose differences are
  written by hand, and its exit statuses against `diff`'s conventions.

## Evidence

| Requirements | Status  | Evidence                                                                                                                                                             | Gap |
| ------------ | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- |
| `XA1`–`XA5`  | planned | the busybox names give byte-equal output; filter options and their exclusion; exit statuses; outputs with standard error closed; the default build's dependency list | —   |
| `XA6`        | planned | the explorer's FXC2 and FXC5 tests over the library; its dependency list                                                                                             | —   |
| `XS1`–`XS4`  | planned | each source form; a ticket-like directory; hostile collection names refused before any content range; git calls refused over a ticket                                | —   |
| `XC1`–`XC7`  | planned | the explorer's FXC5 cases moved to the library, over both backends; a directory in a member's way; a failure halfway                                                 | —   |
| `XV1`–`XV6`  | planned | ids reported equal; a source changed between passes, separate against inline; an iroh source's id before download; a member changed after it was written             | —   |
| `XL1`–`XL4`  | planned | sorted and NUL-separated listings; long rows; the tree equal to the explorer's plain render                                                                          | —   |
| `XD1`–`XD3`  | planned | the five-difference fixture pair; no content fetched comparing with a ticket; exit statuses                                                                          | —   |
| `XR1`–`XR6`  | planned | missing bridge; the requests a counting provider sees; payload bytes for a one-file copy; a corrupt byte; a raw blob ticket; a provider stopped halfway              | —   |
| `XP1`–`XP4`  | planned | callPackage against a nixpkgs checkout; the closure listed and measured; each option combination; the suite on Linux, macOS and Windows                              | —   |
