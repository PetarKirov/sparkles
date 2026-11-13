# `fsx` — Decisions

The choices behind the [specification](./SPEC.md). Each records the
question, the choice, and what was rejected. Choices marked _accepted_ were
made by the owner on 2026-11-13.

## XO1: One program under several names (accepted)

**Question.** The explorer's `cp` subcommand sits behind a UI program and
its subcommand layout. How should a copy with flat options be offered, and
under what name?

**Choice.** A program of its own, `fsx`, with the subcommands `cp`, `ls` and
`diff`, which also behaves as `fscp`, `fsls` or `fsdiff` when run under that
name, as busybox does (`XA1`). Its engine is a library,
`sparkles:fileset-tools`, that the explorer uses too (`XA6`). The name is
provisional and may change.

**Rejected.** The explorer as the busybox, which would make every install
carry the UI stack; a further explorer subcommand with flat options, which
adds little over `cp`; `ferry`, `sift`, `pluck` and `fileset-cp` as names.

## XO2: The smallest closure (accepted)

**Question.** What may `fsx` depend on?

**Choice.** Nothing from the UI stack, and the diff engine and the
highlighted views only in an optional configuration that adds `fsdiff`
(`XA5`). The iroh bridge stays loaded at run time. The package links Phobos
and druntime statically (`XP2`), and is written so that Linux distributions,
nixpkgs first, can take it as it is.

**Rejected.** `fsdiff` in the default build, which would bring `libs/diff`
and `libs/source-view` into every install.

## XO3: Every copy is verified (accepted)

**Question.** Should verification be an option?

**Choice.** No: every copy hashes the source before copying and the
destination after, and succeeds only when the ids agree (`XV1`). By default
the source is hashed in a pass of its own; `--verify=inline` hashes it as
the copy reads instead, reading it once (`XV2`). `--tree-hashes` adds the
NAR and git names to the comparison (`XV4`).

**Rejected.** Verification only with `--tree-hashes`; hashing only inline,
which cannot see a source that changed after it was read.

## XO4: A failed copy is left for inspection (accepted)

**Question.** When verification fails, or a member cannot be copied, what
happens to what was written?

**Choice.** It stays (`XC6`, `XV5`); the error names the first member that
differs.

**Rejected.** Removing what the copy wrote, which loses the evidence and
would make a copy delete files.

## XO5: Listing and comparing (accepted)

**Question.** What do `fsls` and `fsdiff` print?

**Choice.** `fsls`: one path per line in byte order, `-0` for NUL
separators, `-l` for kind, size and link target, `--tree` for the explorer's
tree (`XL1`–`XL3`). `fsdiff A B`: both sides sources, the filter applied to
both, git's `--name-status` letters by content id, `-p` for highlighted
text diffs, and `diff`'s exit statuses (`XD1`–`XD3`).

## XO6: The filter from a file (accepted)

**Question.** A long filter is awkward on a command line. How else can it
be given?

**Choice.** `--filter-file PATH`, `-` for standard input, excluding
`--filter` (`XA2`).

## XO7: Packaging is ready to submit (accepted)

**Question.** How far does the nixpkgs work go?

**Choice.** A `package.nix` in nixpkgs' own style, buildable with
`callPackage` against nixpkgs alone (`XP1`). Submitting it upstream, which
needs a tagged release, is not part of this work.

## XO8: Linux, macOS and Windows (accepted)

**Question.** Which systems does `fsx` support?

**Choice.** All three from the start (`XP4`). macOS is tested on the
owner's machine over SSH; Windows needs the VFS's `pathOf`
([`VFB9`](../base/vfs/backends.md)) through `GetFinalPathNameByHandleW`
and the iroh bridge built for it.

## XO9: An iroh source filters before it downloads (accepted)

**Question.** A copy from an iroh ticket can download the whole collection
and filter locally, or read the collection's metadata, filter, and fetch
only the selection. Which?

**Choice.** The second (`XR2`, `XR3`). The names, the digests and proofs of
the sizes are fetched first; the filter is evaluated over them; only the
selected blobs follow, each verified as it streams (`XR4`). Because a
castore file id is the blob's BLAKE3 digest, the source's id is known
before any content arrives (`XV3`).

**Rejected.** A full download into a temporary directory followed by a local
copy: simpler, but it fetches everything for a filter that selects one
file, and gives up what `fsx` adds over `sendme receive`.

## XO10: The explorer keeps its subcommands (accepted)

**Question.** With `fsx` in place, does the explorer keep `cp`?

**Choice.** Yes, as a thin caller of the library (`XA6`), so existing
command lines keep working.

## XO11: How a ticket is written (proposed)

**Question.** Which forms name an iroh source?

**Choice.** A bare `sendme` ticket, as `sendme` prints it; `iroh:` before
one as the canonical URI, opaque rather than hierarchical since a ticket
names a node, a hash and addresses rather than a host; and
`web+iroh-sendme:`, the form a browser's protocol handler is given, as an
alias (`XS1`). A bare ticket yields to an existing path of the same name.

**Open.** Whether iroh defines a URI scheme of its own; if it does, `fsx`
**should** accept it, and this choice is revisited.

## XO12: A collection's label (proposed)

**Question.** A `sendme` collection prefixes every name with the directory
it was sent from. Is that prefix part of a member's path?

**Choice.** No: when every name shares a first component it is the label,
reported and removed, so that `fscp` from a ticket lays the files out at
`DST/<path>` as a local copy does, and the castore id of the copy equals
the sender's whenever no member was executable, a bit the collection does
not carry (`XS3`).

**Rejected.** Keeping the label, which would make a copy from a ticket
differ in layout and in ids from the same copy made locally.
