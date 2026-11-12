---
status: draft
owner: fileset-explorer
reviewed: 2026-11-09
---

# Fileset explorer — Plan

Each milestone ends with its rows of the [ledger](./testing.md#evidence-ledger)
verified and every commit green.

| Milestone | Scope                                                                                                                                                                                                                                   | Requirements                                                  |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| M1        | The application, moved from the example; the host's text cursor; the stats column at its content width; file-type icons shared with hue                                                                                                 | `FXU1`, `FXU3`, `FXU5`, `FXU6`, `FXU8`, `FXU9`, `HST20`       |
| M2        | The query language as a library, the multi-line editor, the grammar and highlighting                                                                                                                                                    | `FXL1`–`FXL8`, `FXU2`, `FXU4`, `FSV6`, `FSV7`                 |
| M3        | The dock with Stats, Help and Export tabs; the help page                                                                                                                                                                                | `FXU7`                                                        |
| M4        | Try blocks, runners, named trees, the checked tutorial                                                                                                                                                                                  | `FXT1`–`FXT5`                                                 |
| M5        | The generator library, the Export tab and `--emit`; the `nix` target in its three modes                                                                                                                                                 | `FXE1`–`FXE3`, `FXE11`, `FXE12`                               |
| M6        | `git-pathspec` and `gitignore`                                                                                                                                                                                                          | `FXE4`, `FXE5`                                                |
| M7        | `rsync` and `tar`                                                                                                                                                                                                                       | `FXE6`, `FXE7`                                                |
| M8        | `cargo`, `bazel` and `dub`                                                                                                                                                                                                              | `FXE8`–`FXE10`                                                |
| M9        | Touch and momentum scrolling; the Android APK with the repository as its root                                                                                                                                                           | `FXU10`, `FXA1`–`FXA3`                                        |
| M10       | Pixel scrolling in a native window, overlay scrollbars, the I-beam and click-to-caret, a denser type and tree                                                                                                                           | `FXU10`, `FXU11`, `FXU14`–`FXU16`                             |
| M11       | Pills with room around their labels, taps that reach their pane, the cheat sheet's ▶, a long export at frame rate, rounded fences, the I-beam on Android                                                                                | `FXU15`, `FXU17`–`FXU20`                                      |
| M12       | The caret painted on the native host, the clipboard read there and on Android, a soft keyboard's editing keys, segments inside their outline, the Export tab scrolling across and Nix written a path a line                             | `FXU3`, `FXU17`, `FXU21`, `FXU22`                             |
| M13       | Paths relative to the root, calls for the keywords, literal quotes and joined pieces, `\|` and `-` grouped, bare `fileFilter` arguments and `!=`; glob metacharacters highlighted; Export's controls beside the tabs; even fence frames | `FXL1`–`FXL9`, `FXU23`, `FXU24`                               |
| M14       | The git tree, its SRI form and SWHID, the Nix store path and iroh's collection, computed in the one read and shown in Stats; copying a name                                                                                             | `FXS1`, `FXS2`; `CAG3`, `CAT4`, `CAI1`–`CAI3`, `CAP1`, `CAP2` |
| M15       | The iroh bridge, built in `sendme`'s tree and loaded at run time; Send, with its confirmation, progress, ticket, stop and check                                                                                                         | `FXS3`–`FXS8`                                                 |
| M16       | The bridge for Android's arm64, carried by the APK; Send from the tablet                                                                                                                                                                | `FXS9`                                                        |
| M17       | Subcommands: `view` the default, `stats`, `send` and `emit`                                                                                                                                                                             | `FXC1`–`FXC4`, `FXE11`, `FXU8`                                |

Progress: M1–M12 are delivered, M11 and M12 checked on the tablet too; M13 is delivered on Linux and seen on the Android emulator and the tablet; every row of the ledger is verified, the Cargo and
Bazel oracles when their tools are on `PATH`. M14 and M15 are delivered on Linux, the transport checked against `sendme` itself; M16 is delivered, a fileset sent from the tablet and received on the desktop.
