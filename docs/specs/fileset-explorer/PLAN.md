---
status: draft
owner: fileset-explorer
reviewed: 2026-11-09
---

# Fileset explorer — Plan

Each milestone ends with its rows of the [ledger](./testing.md#evidence-ledger)
verified and every commit green.

| Milestone | Scope                                                                                                                                   | Requirements                                            |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| M1        | The application, moved from the example; the host's text cursor; the stats column at its content width; file-type icons shared with hue | `FXU1`, `FXU3`, `FXU5`, `FXU6`, `FXU8`, `FXU9`, `HST20` |
| M2        | The query language as a library, the multi-line editor, the grammar and highlighting                                                    | `FXL1`–`FXL8`, `FXU2`, `FXU4`, `FSV6`, `FSV7`           |
| M3        | The dock with Stats, Help and Export tabs; the help page                                                                                | `FXU7`                                                  |
| M4        | Try blocks, runners, named trees, the checked tutorial                                                                                  | `FXT1`–`FXT5`                                           |
| M5        | The generator library, the Export tab and `--emit`; the `nix` target in its three modes                                                 | `FXE1`–`FXE3`, `FXE11`, `FXE12`                         |
| M6        | `git-pathspec` and `gitignore`                                                                                                          | `FXE4`, `FXE5`                                          |
| M7        | `rsync` and `tar`                                                                                                                       | `FXE6`, `FXE7`                                          |
| M8        | `cargo`, `bazel` and `dub`                                                                                                              | `FXE8`–`FXE10`                                          |

Progress: M1–M8 are delivered; every row of the ledger is verified, the Cargo and
Bazel oracles when their tools are on `PATH`.
