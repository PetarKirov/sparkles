# Fileset explorer

The fileset explorer is for writing a fileset and seeing what it selects as you
write it. Every edit of the query re-resolves it against the directory, and the
members are drawn as a tree, with their numbers beside them, and the same
fileset written for Nix, git, rsync, tar, Cargo, Bazel and dub in the Export
tab.

```sh
nix run github:PetarKirov/sparkles#fileset-explorer -- --dir . --query '**/*.d - **/*_test.d'
```

This page is also the explorer's help: `F1` opens it beside the tree.
Each tutorial block has a ▶ button that loads its query into the editor and
shows the result.

## Cheat sheet

| Write                                  | Selects                                                                  |
| -------------------------------------- | ------------------------------------------------------------------------ |
| `**/*.d`                               | every `.d` file, at any depth                                            |
| `*.d`                                  | the `.d` files at the root                                               |
| `src/*.d`                              | the `.d` files directly in `src`                                         |
| `README.md`, `./README.md`             | `README.md` at the root                                                  |
| `src`, `src/**`                        | everything beneath `src`                                                 |
| `*.{d,di}`, `[ab]*`, `?.d`             | alternatives, classes and single characters: the glob metacharacters     |
| `"my notes"/*.md`                      | a quoted piece is literal and may hold spaces; it joins the pieces by it |
| `"[draft].md"`, `\*.md`                | a name holding metacharacters: quoted, or each escaped with `\`          |
| `all()`, `none()`                      | every file, no file                                                      |
| `exec()`                               | executable files                                                         |
| `gitignored()`, `gitTracked()`         | what git ignores; what git's index holds                                 |
| `a \| b`, `a & b`, `a - b`             | union, intersection, difference; `&` binds tighter                       |
| `(a \| b) - c`, `a \| (b - c)`         | `\|` beside `-` needs parentheses                                        |
| `unions(a, b, …)`                      | the union, as Nix spells it                                              |
| `intersection(a, b)`                   | the intersection                                                         |
| `difference(a, b)`                     | the difference                                                           |
| `fileFilter(hasExt(d))`                | files with that extension, by their own name                             |
| `fileFilter(name == dub.sdl)`          | files with that name; a directory so named selects nothing               |
| `fileFilter(name != *_test.d)`         | a bare name is a glob, a quoted one literal; `!=` is the files it misses |
| `fileFilter(type == symlink)`          | symbolic links (or `regular`)                                            |
| `fileFilter(p && q)`, `p \|\| q`, `!p` | predicates combined                                                      |
| `# …`                                  | a comment, to the end of the line                                        |

A query may span lines. A path is relative to the root, as a Nix path is:
`README.md` is the root's, and `**/README.md` every one; a leading `/` is an
error. Operators must stand apart from paths: `a-b.d` is one path, `a - b.d` a
difference. A `#` starts a comment only where a token could start, so `a#b` is
a path. A bare `all` is the path `all`, and the result says so when nothing has
that name.

## Keys

| Key                | Does                                                   |
| ------------------ | ------------------------------------------------------ |
| `Tab`, `Shift+Tab` | moves between the query, the tree and the right tabs   |
| `Ctrl+Enter`       | leaves the query for the tree                          |
| `↑` `↓`            | in a one-line query, move in the tree                  |
| `←` `→`            | in the tree, close and open; in the right tabs, switch |
| `o`, `c`           | open or close every directory                          |
| `i`                | computes the ids of a fileset too large to do it live  |
| `n`, `p`, `Enter`  | in the help, select a try block and run it             |
| `F1`               | shows the help, or goes back                           |
| `Esc`              | leaves a tutorial's tree; otherwise quits              |

With a mouse or a finger, a tab shows its pane when tapped, the Export tab's
◀ ▶, glob mode and copy do what `T` `t`, `g` and `y` do, and a tap on the query
gives it focus. A finger drags the tree, the help and the code, and a flick
keeps them coasting.

On Android, `nix build .#fileset-explorer-apk` builds an APK whose fileset root
is the sparkles repository itself, every tracked file but the dotfiles, which
Android cannot ship.

## Tutorial

The blocks below run on this small project, held in memory:

```tree-literal {#tutorial}
src/app.d = module app;
src/lib.d = module lib;
src/lib_test.d = unittest
src/util/strings.d = module util.strings;
docs/guide.md = Guide
README.md = hello
dub.sdl = name "app"
bin/run +x = exec
build/app.o = obj
```

A `**/` matches at any depth; without it, a path starts at the root:

::: try fileset {tree=tutorial}

```fileset
**/*.d
```

```tree
src/
├─ app.d
├─ lib.d
├─ lib_test.d
└─ util/
   └─ strings.d
```

:::

A difference takes the tests out, and a comment says why:

::: try fileset {tree=tutorial}

```fileset
src/**/*.d - **/*_test.d  # sources, not tests
```

```tree
src/
├─ app.d
├─ lib.d
└─ util/
   └─ strings.d
```

:::

A union adds what another path selects:

::: try fileset {tree=tutorial}

```fileset
**/*.md | dub.sdl
```

```tree
README.md
docs/
└─ guide.md
dub.sdl
```

:::

An intersection keeps what both select:

::: try fileset {tree=tutorial}

```fileset
src & **/*_test.d
```

```tree
src/
└─ lib_test.d
```

:::

`exec()` holds the executable files:

::: try fileset {tree=tutorial}

```fileset
exec()
```

```tree
bin/
└─ run
```

:::

`fileFilter` decides each file by its own name, as Nix's does:

::: try fileset {tree=tutorial}

```fileset
fileFilter(hasExt(d) && name != app.d)
```

```tree
src/
├─ lib.d
├─ lib_test.d
└─ util/
   └─ strings.d
```

:::

A bare name is a glob over each file's own name; quoted, it is literal:

::: try fileset {tree=tutorial}

```fileset
fileFilter(name == *_test.d)
```

```tree
src/
└─ lib_test.d
```

:::

Everything but the build's outputs, as a source archive holds it:

::: try fileset {tree=tutorial}

```fileset
all() - build - bin
```

```tree
README.md
docs/
└─ guide.md
dub.sdl
src/
├─ app.d
├─ lib.d
├─ lib_test.d
└─ util/
   └─ strings.d
```

:::

A block that names no tree runs on the directory you opened:

::: try fileset

```fileset
gitTracked() & **/*.md
```

:::

## Export

The Export tab writes the query for another system, or says why that system
cannot express it. A translation is never approximate: the files it selects are
exactly the members, checked against each system's own tool.

| Target         | Accepts                                                                      |
| -------------- | ---------------------------------------------------------------------------- |
| `nix`          | everything but `exec()` and the case-insensitive policy; globs by a shim     |
| `git-pathspec` | a union of globs minus a union of globs, with `gitTracked()`                 |
| `gitignore`    | what `rsync` accepts                                                         |
| `rsync`        | unions and differences in which each right side is a glob or a union of them |
| `tar`          | literal paths and `dir/**`, minus globs                                      |
| `cargo`        | a union of globs that keeps `Cargo.toml`                                     |
| `bazel`        | a union of globs minus a union of globs, without character classes           |
| `dub`          | a union of globs minus a union of globs                                      |

Nix has no globs: `lib.fileset` takes paths and `fileFilter`. A glob reaches it
in one of three ways, chosen in the tab: a small `glob` function the output
defines, which walks the tree with `builtins.readDir` when Nix evaluates it (the
default); the paths the glob matches now, marked as a snapshot; or a refusal,
for anything but a literal path or a name pattern.

## From the command line

The same fileset can be used without the screen. `stats` prints what the
Stats tab shows, its names among them (`--ids` computes them for a large
fileset); `send` serves it as `sendme send` serves a directory, asking first
unless given `--yes`; `emit` writes it for another build system; and `cp`
copies its members to a directory, each at its path, executable bits and
links kept, nothing copied over a file that is there unless given
`--force`, and only listed with `--dry-run`. A link pointing to an absolute
path is copied only into a place granted with `--link-root`, such as
`/nix/store`; without one, `cp` names it and copies nothing:

```sh
fileset-explorer --dir . --query 'src/**' stats
fileset-explorer --dir . --query 'src/**' send --yes
fileset-explorer --dir . --query 'src/**' emit nix
fileset-explorer --dir . --query 'src/**' cp ../snapshot
```
