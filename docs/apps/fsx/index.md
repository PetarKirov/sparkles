# fsx

`fsx` copies and lists the files a fileset selects from a tree, with the
filter written in the fileset query language the
[fileset explorer](../fileset-explorer/index.md) uses. It is one program
under several names: `fscp` is `fsx cp`, and `fsls` is `fsx ls`
([specification](../../specs/fsx/SPEC.md)).

## Installing

```sh
nix build .#fsx        # fsx, fscp, fsls
nix build .#fsx-full   # and fsdiff
```

Both come from `apps/fsx/package.nix`, written as nixpkgs writes a package,
so that it builds with nixpkgs alone (`callPackage`, nixpkgs' LDC and
`buildDubPackage`). Phobos is linked in; at run time `fsx` needs the C
library and libgcc, and, to read from an iroh peer, the iroh bridge, which
the package builds and the program finds through its own run path.

## Copying

```sh
fscp --src . --filter 'gitTracked() - fileFilter(type == symlink)' --dst ../snapshot
```

Each member is written to `DST/<path>`, its path from the source's root,
with its contents and executable bit; a link stays a link. Nothing is
written over a path that exists unless `-f` asks for it, and a directory in
a member's way is never replaced. `-n` lists the destination paths and
copies nothing. A link with an absolute target is copied only into a
directory granted with `--link-root`, such as `/nix/store`.

Every copy is verified. The source's members are hashed before the copy,
or as it reads them with `--verify inline`, and the copied members after
it; the copy succeeds only when the two castore ids agree, and otherwise
names the first member that differs and leaves the copy for inspection.
`--tree-hashes` checks the NAR hash and the git tree id as well:

```text
fscp: copied 5343 files (94.5 MiB) to ../snapshot in 382.62 ms (BlockingVfs)
fscp: verified: castore blake3-zGwLWk1ZLsukDbY+H9EEk3KMR0o4gREUUiAp0vqoVPI=
```

## From another machine

`--src` takes a `sendme` ticket too, bare as `sendme send` prints it or as
`iroh:<ticket>`. `fsx` reads the collection's names first, a few KiB, then
evaluates the filter over them and downloads only the files it selects,
each verified against its BLAKE3 digest as it arrives:

```sh
fscp --src blobadkwdeu5… --filter 'src/** - **/*_test.d' --dst ./ci
```

```text
fscp: copied 31 files (742.9 KiB) of 52 from `ci` from the peer to ./ci in 24.55 ms (iroh; opening it read 2.9 KiB)
fscp: verified: castore blake3-Letqr/k4yTNbC0ABAPCg8F4UsJGjJ2/y3oAC3IeZJUs=
```

The files land at their paths beneath the directory `sendme` sent, without
its name, and without executable bits, which a collection does not carry.
A filter over a ticket cannot ask git: `gitTracked()` and `gitignored()` are
refused.

## Listing

```sh
fsls --src . --filter 'src/**'          # one path per line, sorted
fsls --src . --filter 'src/**' -l       # kind, size, path, a link's target
fsls --src . --filter 'src/**' --tree   # as a tree
fsls --src . --filter 'src/**' -0 | xargs -0 wc -l
```

## Comparing

`fsdiff`, in the `full` build (`dub build :fsx -c full`), compares the
members of one filter over two sources, either of them a ticket, by
content id, and prints git's `--name-status` letters; `-p` adds a unified
diff of each changed text file. It exits 0 when they are equal and 1 when
they differ, as `diff` does. Against a ticket only the names are fetched,
and with `-p` the changed files:

```sh
fsdiff . blobadkwdeu5… --filter 'src/**'
```

`--filter-file PATH` reads the filter from a file, `-` from standard input.
What a subcommand produces goes to standard output; its reports, with
`--stats` and `--tree-hashes`, go to standard error.
