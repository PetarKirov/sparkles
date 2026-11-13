---
status: draft
owner: sparkles:fileset-tools
reviewed: 2026-11-13
---

# `fsx` and `sparkles:fileset-tools` — Specification

## Abstract

`fsx` is a command-line tool that copies, lists and compares the files a
fileset selects from a tree, where the tree is a local directory or a
collection another machine serves over iroh. The filter is the fileset query
language, so a selection means the same files in a terminal, in a build and
in the fileset explorer. Every copy is verified: the destination is hashed
after it is written and must carry the content ids the source's selection
had. From an iroh peer, the filter is evaluated against the collection's
names and sizes before any file is fetched, and only the selected files are
downloaded. `sparkles:fileset-tools` is the library underneath, shared with
the fileset explorer.

## Introduction

Developers, build scripts and packagers often need a part of a tree, not all
of it: the sources of one package, a snapshot of what a fileset selects, the
same files on another machine. The tools for this each have their own
notion of a selection. `cp` has none, `rsync` and `tar` have include and
exclude rules with their own matching, and `git archive` has pathspecs.
None of them says what the fileset library means by a fileset, so a
selection written for the [fileset explorer](../fileset-explorer/SPEC.md) or
a build has to be translated, and a translation can be subtly wrong. None of
them proves that the copy holds what was selected either, and `sendme
receive`, iroh's file receiver, can only fetch a whole collection.

`fsx` takes the fileset library's meaning as its own. A _source_ is a tree
the filter is evaluated against, together with a way to read the selected
files; a local directory is one, and an iroh collection named by a ticket is
another. Whatever the source, the selection is a set of _members_, each a
regular file or a symbolic link at a path from the source's root, and the
same content ids the explorer shows name that set. Copying is checked
against those ids end to end: the source's ids are computed before the
copy, or as it reads, and the destination's after it, and a copy whose ids
differ fails. Because a castore file id is the BLAKE3 digest that also names
an iroh blob, an iroh source's ids are known from its metadata alone, so the
filter and the expected result are settled before any content is
downloaded.

Several things are out of scope. `fsx` does not send: serving a fileset is
the explorer's ([`FXS3`](../fileset-explorer/SPEC.md)), and an `fsx send`
would be a separate contract. It does not synchronize or delete: a copy adds
members to a destination and refuses to overwrite one that exists unless
told to, but never removes anything there. It does not watch a tree, write
to a remote destination, or read a git revision rather than a working tree.
The query language itself is the explorer's
([§2](../fileset-explorer/SPEC.md)), resolved by the fileset library, and
the ids are [content addressing's](../build-primitives/content-addressing/SPEC.md);
this contract uses both and restates neither.

The command line and the packages are in §2, sources in §3, copying in §4
and its verification in §5. Listing is §6, comparing §7, the iroh source §8,
and packaging §9. The choices behind them are in [decisions](./decisions.md),
the delivery order in the [plan](./PLAN.md), and the evidence in
[testing](./testing.md).

## 1. Invariants

1. **One meaning.** The members of a filter over a source are the members the
   fileset library resolves it to over that source's tree, and every
   subcommand describes exactly those.
2. **Verified or failed.** A copy succeeds only when the destination, hashed
   after it was written, has the ids the source's members had.
3. **Nothing is lost.** No subcommand removes a file that existed before it
   ran, overwrites one without `--force`, or deletes what it wrote when it
   fails: a failed copy is left for inspection.
4. **Authority is explicit.** `fsx` opens only the source, the destination's
   parent and the roots granted for absolute links, each where the command
   line names it; everything beneath is reached through the capability VFS.
5. **Remote bytes are verified before they are used.** No byte from an iroh
   peer reaches a destination or a comparison before it has been checked
   against the BLAKE3 digest that names it.

## 2. The command line and the packages (`XA`)

**`XA1` — One program, several names.** `fsx` **must** accept the
subcommands `cp`, `ls` and `diff`. Run under the name `fscp`, `fsls` or
`fsdiff`, the program **must** behave as `fsx cp`, `fsx ls` or `fsx diff`
given the same arguments; the name is the last component of the program's
path, with a `.exe` suffix dropped on Windows. Under any other name it is
`fsx`. _Detection:_ the same arguments run through `fsx cp` and through a
link named `fscp` produce byte-equal output and the same exit status, and
so do `ls` and `diff`.

**`XA2` — The filter.** `cp` and `ls` **must** take the filter as
`--filter EXPR`, a query of the fileset query language, or as
`--filter-file PATH`, a file whose contents are the query, `-` naming
standard input; giving both is a usage error. Without either the filter is
`all()`. A filter that does not parse **must** exit 1 with the parser's
message and position, before the source is read beyond what resolving it
needs. _Detection:_ `--filter 'src/**'` and a file holding `src/**` select
the same members; both options together exit 2; `--filter '('` exits 1
naming the position.

**`XA3` — Exit statuses.** Every subcommand **must** exit 0 on success, 1
when the operation fails or is refused, and 2 on a usage error: an unknown
option, a missing argument, or options that exclude each other. `diff`
replaces 0 and 1 with its own meaning (`XD3`).

**`XA4` — Output streams.** What a subcommand produces, the listing of `ls`
and the comparison of `diff`, **must** go to standard output; progress,
summaries, reports and errors **must** go to standard error, so that
standard output can be piped. _Detection:_ with standard error closed, the
output of `ls` and `diff` is unchanged.

**`XA5` — A small program.** The default build of `fsx` **must not** link
any of the toolkit's UI, windowing or GPU packages, nor the diff engine,
the syntax highlighter or tree-sitter; the iroh bridge **must** be loaded at
run time, so that a build without it still copies, lists and compares local
trees. `diff` belongs to a separate build configuration that adds the diff
engine and the highlighted views; the default build, run as `fsdiff` or
given `diff`, **must** exit 2 saying it was built without it. _Detection:_
the default build's dependency list, from `dub describe`, holds none of the
named packages, and its executable runs `cp` with the bridge's path unset.

**`XA6` — The library.** `sparkles:fileset-tools` **must** hold the parts
the explorer and `fsx` share: resolving a filter over a source, the members
and their ids, copying, verification, and the Stats report. It **must not**
depend on the toolkit's UI packages, so that `fsx` can use it without them,
and the explorer's `stats`, `send` and `cp` subcommands **must** be thin
callers of it. _Detection:_ `dub describe :fileset-tools` lists no UI
package, and the explorer's `FXC2` and `FXC5` tests pass against it.

## 3. Sources (`XS`)

**`XS1` — Naming a source.** `--src` and `diff`'s two arguments **must**
accept a source as:

- a path to a directory, absolute or relative to the working directory;
- a `file:` URI naming one;
- `iroh:` followed by a `sendme` ticket, or `web+iroh-sendme:` followed by
  one, the form a browser's protocol handler receives;
- a bare `sendme` ticket, when it parses as one and no file of that name
  exists in the working directory. `./` before it names the path instead.

Anything else **must** be refused, exit 1, saying what was expected.
_Rationale:_ a bare ticket is what `sendme send` prints and what people
paste, and the existence check keeps a directory that happens to look like
one reachable. _Detection:_ each form names the same source; a directory
named like a ticket is the path, and `./` reaches it explicitly.

**`XS2` — A local source.** A local source's tree **must** be the directory
as the fileset library resolves it: links are members, never followed, and
`all()` selects everything beneath the root, a `.git` directory included.
The source is opened read-only. _Detection:_ `ls` over a tree holding a
link, an executable file and a `.git` directory lists all three with
`all()`, and the link's target is not read.

**`XS3` — An iroh source's tree.** An iroh source's tree **must** be the
collection's names: each name is a member regular file, not executable,
with the size the peer proves for it (`XR2`). When every name begins with
the same first component, that component is the collection's _label_
([`CAI1`](../build-primitives/content-addressing/SPEC.md#_8-iroh-s-collection-cai))
and is removed from every path; the label is reported, not copied. Before
any file's contents are fetched, every name **must** be checked: one that
is empty, absolute, holds an empty, `.` or `..` component or a `\`, is not
UTF-8, repeats another, or is both a file and a directory of another name
**must** refuse the source, naming it. _Rationale:_ a collection's names are
chosen by whoever serves it, so they are hostile input until checked.
_Detection:_ a collection with names `L/a`, `L/b/c` has members `a` and
`b/c` and the label `L`; collections holding `L/../x`, `/x`, `L//x`, `L/a`
twice, and `L/a` beside `L/a/b` are each refused before any blob beyond the
metadata is requested.

**`XS4` — What an iroh source cannot answer.** A filter over an iroh source
**must** be refused, exit 1, when it holds a call that needs a git
repository or `.gitignore` scopes (`gitTracked()`, `gitignored()`), which a
collection does not carry. The executable and link predicates select
nothing there, as a collection has neither
([`CAI2`](../build-primitives/content-addressing/SPEC.md#_8-iroh-s-collection-cai)).
_Detection:_ `gitTracked()` over a ticket exits 1 naming the call;
`fileFilter(type == symlink)` selects no member.

## 4. Copying (`XC`)

`fscp --src SRC --dst DST [--filter EXPR]` copies the members of the filter
over the source to the destination.

**`XC1` — The layout.** Each member **must** be written to `DST/<path>`, its
path from the source's root, with the directories on the way created; `DST`
itself is created if it is missing, its parent **must** exist. Nothing is
written outside `DST`. _Detection:_ a fileset of `a`, `b/c` and `b/d/e`
copied to a missing `DST` gives exactly those three files under it.

**`XC2` — Nothing over what exists.** Before writing anything, `fscp`
**must** check every destination path; when any exists, as a file, a link
or a directory, it **must** write nothing and exit 1 naming them, unless
`-f`/`--force` asks to replace them, which removes each such entry just
before its member is written. A directory in a member's way is not
replaced, even with `--force`: the copy fails naming it. _Detection:_ a
second copy over the first refuses, naming the paths, and leaves them
unchanged; `--force` replaces a changed file; a directory at a member's path
fails the copy with or without `--force`.

**`XC3` — Members as they are.** A regular file **must** be written with its
contents and its executable bit; a link **must** be written as a link
holding the target it holds in the source, and is never followed. An iroh
source's members are written without the executable bit, as they have none
(`XS3`). _Detection:_ the kinds fixture copied has the same executable files
and the same link targets; a link to a missing target is copied.

**`XC4` — Absolute links need a granted root.** A link whose target is
absolute **must** be copied only when the target falls lexically beneath a
directory given with `--link-root PATH`, repeatable, which the command line
opens read-only, and **must** be made through that directory so that it
holds the directory's real path
([`VFO10`](../base/vfs/SPEC.md#vfo10-symbolic-link-targets)). When any such
link falls beneath none, `fscp` **must** write nothing, name each, and exit
1, a dry run included. _Detection:_ a link into a temporary store is refused
without `--link-root` and copied with it, holding the store's real path when
it is reached through a link.

**`XC5` — A dry run.** `-n`/`--dry-run` **must** print each destination path
on standard output, the totals on standard error, apply every check of
`XC2` and `XC4`, and write nothing. _Detection:_ a dry run lists the paths
and leaves `DST` absent; a dry run over existing paths exits 1 as the copy
would.

**`XC6` — A failure stops the copy.** A member that cannot be read or written
**must** stop the copy: nothing more is started, what was written stays, and
`fscp` exits 1 naming the member and the reason. _Detection:_ a destination
directory made read-only halfway fails the copy, naming the first member it
refused, and the members written before it remain.

**`XC7` — The backend.** `--vfs blocking`, the default, **must** copy one
file at a time on the calling thread; `--vfs ring` **must** copy up to
`--jobs N` files at once on the event loop. Both **must** produce the same
destination. _Detection:_ the same copy over each backend gives trees with
equal ids, and the ring backend reports more than one file in flight.

## 5. Verification (`XV`)

**`XV1` — Every copy is verified.** Before exiting 0, `fscp` **must** hash
the destination's copied members, exactly the members' paths under `DST`
and nothing else beneath it, and compare the castore id
([`CAC1`, `CAC2`](../build-primitives/content-addressing/SPEC.md#_3-castore-cac))
with the castore id of the tree the copy is to make: the source's members,
each link made through a granted root holding the target `XC4` gives it.
They **must** be equal for the copy to succeed; when every granted root is
named by its real path, that tree is the source's. _Detection:_ every successful copy reports both ids, equal; a
destination that already held unrelated files still verifies, as they are
not members.

**`XV2` — When the source is hashed.** With `--verify=separate`, the
default, the source's members **must** be hashed in a pass of their own
before any member is written; with `--verify=inline` they **must** be hashed
from the bytes as the copy reads them. _Rationale:_ the separate pass also
fails a copy whose source changed after it was hashed, since the
destination then differs from what was hashed; the inline pass reads the
source once and proves only that the destination holds the bytes read.
_Detection:_ a source file rewritten between the two passes, through a hook
the test drives, fails a separate copy and passes an inline one; both modes
read a member's bytes the stated number of times.

**`XV3` — An iroh source's ids come first.** For an iroh source, the
source's castore id **must** be computed from the names, the BLAKE3 digests
and the proved sizes of the selected members, before any of their contents
is fetched, whichever `--verify` says. _Detection:_ the id reported before
the download equals the castore id of the same files materialized locally
with no executable bit.

**`XV4` — More names.** `--tree-hashes` **must** add the NAR hash and the git
tree id ([`CAN1`](../build-primitives/content-addressing/SPEC.md#_4-nar-can),
[`CAG1`](../build-primitives/content-addressing/SPEC.md#_5-git-trees-cag)),
print every name for the source and for the destination, and require each
pair to be equal. When a link would hold a granted root's real path rather
than the source's target, no copy can have the source's names, and
`--tree-hashes` **must** refuse before writing anything, naming the link. For an iroh source these two are computed from the bytes
as they arrive, as neither is known before. _Detection:_ with
`--tree-hashes` the report lists the three names twice, equal, matching
what `fileset-explorer stats --ids` names for the same members.

**`XV5` — A mismatch.** When an id differs, `fscp` **must** exit 1, name the
first member in path order whose digest, size, executable bit or link
target differs, print both ids, and leave the destination as it is.
_Detection:_ a member changed after the copy wrote it, through the test's
hook, fails the copy naming that member, and the destination still holds
every member written.

**`XV6` — The report.** `--stats` **must** print the source's Stats report,
the lines the explorer's Stats tab shows for the same members
([`FXC2`](../fileset-explorer/SPEC.md)), on standard error before the copy
starts. _Detection:_ the lines equal `fileset-explorer stats` for the same
source and filter.

## 6. Listing (`XL`)

`fsls --src SRC [--filter EXPR]` lists the members.

**`XL1` — One path per line.** `fsls` **must** print each member's path from
the source's root, one per line, in the byte order of the paths, on
standard output; `-0`/`--null` ends each path with a NUL byte instead.
_Detection:_ the listing of the kinds fixture equals its paths sorted by
bytes; with `--null` it splits on NUL into the same list.

**`XL2` — The long form.** `-l`/`--long` **must** print, for each member, its
kind and executable bit as `f`, `x` or `l`, its size in bytes, its path,
and for a link `->` and its target, separated by tabs. _Detection:_ a
fixture with an executable file, a plain file and a link gives three rows
whose fields are exactly those values.

**`XL3` — The tree.** `--tree` **must** draw the members as the explorer's
member tree draws them: directories first, each entry under its parent,
connectors between them. _Detection:_ the drawn lines equal the explorer's
plain render of the same members.

**`XL4` — Numbers and names.** `--stats` and `--tree-hashes` **must** print
the Stats report and the members' castore, NAR and git ids on standard
error, after the listing. _Detection:_ standard output is unchanged by
either option, and standard error holds the explorer's lines and ids.

## 7. Comparing (`XD`)

`fsdiff A B [--filter EXPR]` compares the members of the filter over two
sources, both resolved with the same filter.

**`XD1` — What differs.** `fsdiff` **must** print one line per path that is
a member of either side and differs, in byte order: `A` for a member of
`B` only, `D` for one of `A` only, `M` for a member of both whose contents or
executable bit differ, and `T` for one that is a file on one side and a
link on the other, then a tab and the path. Two files are equal when their
BLAKE3 digests, sizes and executable bits are; two links when their targets
are. _Detection:_ a pair of fixtures differing in one file each way, one
changed file, one executable bit and one file turned into a link gives
exactly those five lines.

**`XD2` — Contents only when needed.** `fsdiff` **must** decide `XD1` from
digests: a file of an iroh source is never fetched to compare it, and a
local one is read only to hash it. `-p`/`--patch` **must** add, for each `M`
whose two sides are UTF-8 text, a unified diff of their lines, highlighted
when standard output is a terminal; only then are an iroh source's changed
files fetched. _Detection:_ comparing a local tree with a ticket fetches no
blob beyond the metadata and sizes; `--patch` fetches the changed files
alone.

**`XD3` — The status.** `fsdiff` **must** exit 0 when the two sides' members
are equal, 1 when they differ, and 2 on trouble, as `diff` does.
_Detection:_ equal fixtures exit 0 and print nothing; differing ones exit 1;
a missing source exits 2.

## 8. The iroh source (`XR`)

An iroh source is reached through the iroh bridge, the library
`sparkles:iroh-send` loads at run time and the explorer already uses to
send.

**`XR1` — Without the bridge.** When the bridge cannot be loaded, a
subcommand given an iroh source **must** exit 1 saying why, and one given
only local sources **must** be unaffected. _Detection:_ with the bridge's
path pointing nowhere, `fscp` from a ticket exits 1 naming the path, and a
local copy succeeds.

**`XR2` — The metadata first.** An iroh source **must** be opened by fetching
the collection's hash sequence, its metadata blob and a proof of each
file's size, and nothing else, before the filter is evaluated. A size is
proved by the last chunk of the blob, verified against its digest.
_Detection:_ opening a collection of `n` files against a counting provider
requests the sequence, the metadata blob and one last-chunk range per file,
and no other range.

**`XR3` — Only the selected files.** The contents fetched after opening
**must** be those of the selected members alone. _Detection:_ copying one
file of a 50-file collection served by the repository's own provider makes
the provider report payload bytes below the metadata's, the size proofs'
and that file's size, with the proof overhead the bao encoding states.

**`XR4` — Verified before written.** Each range of a blob **must** be
verified against the blob's digest before any byte of it is written or
compared; a range that does not verify **must** fail the operation, naming
the member, and no byte of it is written. _Detection:_ a provider
stand-in that flips one byte of a blob fails the copy naming that member,
and the destination file holds no byte past the last verified group.

**`XR5` — A collection, not a blob.** A ticket naming a single blob rather
than a hash sequence **must** be refused, exit 1, saying that `fsx` reads
collections. _Detection:_ a raw blob's ticket is refused before any range is
requested.

**`XR6` — Going away.** A peer that closes the connection, or cannot be
reached before the connection timeout, **must** fail the operation, exit 1,
with the reason; an interrupt **must** stop it the same way. Members written
before either stay, as `XC6` says. _Detection:_ stopping the provider
halfway through a copy fails it with the provider's reason and leaves the
members already written.

## 9. Packaging (`XP`)

**`XP1` — A package nixpkgs can take.** The repository **must** carry a
`package.nix` for `fsx` written as nixpkgs writes a package: called with
`callPackage` and only nixpkgs' own arguments, building with nixpkgs'
`buildDubPackage` from a dub lock it carries, offline, and using no input
of the repository's flake. _Detection:_ `nix-build` of the file through
`callPackage` against a nixpkgs checkout, with the flake absent, builds it
and runs its tests.

**`XP2` — A small closure.** The package **must** link Phobos and druntime
statically, build with the `checked` build type, and depend at run time on
nothing beyond the C library and, with the iroh bridge, the bridge.
_Detection:_ the closure of the default package lists only those, and its
size is recorded in [testing](./testing.md).

**`XP3` — The names and the options.** The package **must** install `fsx`
with `fscp` and `fsls` as links to it, and `fsdiff` when built with the
`withDiff` option, off by default; `withIroh`, on by default, **must**
build the bridge and make the program find it without an environment
variable. _Detection:_ each combination of the two options builds, installs
exactly the names it promises, and copies from a ticket only with
`withIroh`.

**`XP4` — Three systems.** `fsx` **must** build and pass its tests on Linux,
macOS and Windows. On Windows a link is created as a symbolic link, which
needs the privilege or developer mode the system requires; without it a
link member **must** fail the copy naming it, as `XC6` says. _Detection:_
the test suite passes on each system, and on Windows without the privilege
the copy of a link fails, naming it.

## 10. Surface

Non-normative: where the parts live.

| Requirements                                 | Where                                                                            |
| -------------------------------------------- | -------------------------------------------------------------------------------- |
| `XA1`–`XA5`, `XL1`–`XL4`                     | `apps/fsx`                                                                       |
| `XA6`, `XS1`–`XS4`, `XV1`–`XV6`, `XC1`–`XC7` | `libs/fileset-tools`                                                             |
| `XD1`–`XD3`                                  | `apps/fsx`, in its `full` configuration, over `libs/diff` and `libs/source-view` |
| `XR1`–`XR6`                                  | `libs/fileset-tools` (the source), `libs/iroh-send` (the bridge's receive half)  |
| `XP1`–`XP4`                                  | `apps/fsx/package.nix`                                                           |
