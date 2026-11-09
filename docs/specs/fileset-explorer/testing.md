---
status: draft
owner: fileset-explorer
reviewed: 2026-11-09
---

# Fileset explorer — Testing

Every requirement of the [contract](./SPEC.md) is checked by a unit test of the
module that owns it, or by a recorded run of the explorer (`runAppRecorded`),
which drives the real component with scripted events and no terminal.

## Oracles

The generators (`FXE`) are where the explorer could be wrong without noticing:
a translation that looks right selects different files. Each target is
therefore checked by the tool that defines its meaning, on the same trees the
fileset library is checked on.

| Target         | Oracle                                                                                                | Where it comes from                                |
| -------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `nix`          | `nix eval` of `lib.fileset.toList` over the emitted expression, against the materialized tree         | the host's Nix; `<nixpkgs>` from the flake's input |
| `git-pathspec` | `git ls-files --cached --others` with the emitted pathspecs, in a fresh repository holding the tree   | the host's git                                     |
| `gitignore`    | `git ls-files --others --exclude-standard` in a fresh repository with the emitted `.gitignore`        | the host's git                                     |
| `rsync`        | `rsync -r --dry-run --out-format=%n --prune-empty-dirs --filter='merge FILE'` into an empty directory | `rsync` in the dev shell                           |
| `tar`          | `tar -tf` of the archive the emitted command creates                                                  | GNU tar in the dev shell                           |
| `cargo`        | `cargo package --list --allow-dirty --offline` of a crate holding the tree                            | `cargo` in the dev shell                           |
| `bazel`        | `bazel query 'labels(srcs, //:x)'` of a package whose `BUILD` holds the emitted `glob`                | `bazel` when on `PATH`; skipped otherwise          |
| `dub`          | `dub describe --data=source-files` of a package whose recipe holds the emitted settings               | the dev shell's dub                                |

Each oracle test runs every query of the generator corpus
(`fileset/emit/testing.d`) that the target accepts, on the fileset library's
fixture trees and seeded random trees, and compares the oracle's list with the
resolution's members. A query the target refuses is checked to be refused for
the documented reason. The corpus has, for every target, at least one query
just inside its grammar and one just outside.

The query language has two independent checks: the canonical form re-parses
to the same members (`FXL7`), and the tree-sitter grammar, generated from its
own `grammar.js`, agrees with the D parser on every corpus query (`FXL8`).

The tutorial checks itself: every try block's expected result is compared with
its runner's result (`FXT5`), so the help cannot describe a result the
explorer does not give.

## Evidence ledger

Evidence is from Linux x86_64 with DMD and LDC. A requirement the ledger does
not list is unverified.

| Requirements | State       | Evidence | Gap |
| ------------ | ----------- | -------- | --- |
| all          | not started | —        | —   |
