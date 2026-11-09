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

| Write                                  | Selects                                                             |
| -------------------------------------- | ------------------------------------------------------------------- |
| `*.d`                                  | every file named `*.d`, at any depth                                |
| `src/*.d`                              | the `.d` files directly in `src`: a `/` anchors to the root         |
| `/README.md`                           | `README.md` at the root only                                        |
| `src/**`                               | everything beneath `src`                                            |
| `docs`                                 | a file named `docs`, and everything beneath any directory so named  |
| `*.{d,di}`, `[ab]*`, `?.d`             | alternatives, classes and single characters                         |
| `"a b"`, `"#x#"`                       | a glob with spaces, `#` or other characters a bare glob cannot hold |
| `all`, `none`                          | every file, no file                                                 |
| `exec`                                 | executable files                                                    |
| `gitignored`, `gitTracked`             | what git ignores; what git's index holds                            |
| `a \| b`, `a & b`, `a - b`             | union, intersection, difference; `&` binds tighter                  |
| `unions(a, b, …)`                      | the union, as Nix spells it                                         |
| `intersection(a, b)`                   | the intersection                                                    |
| `difference(a, b)`                     | the difference                                                      |
| `fileFilter(hasExt("d"))`              | files with that extension, by their own name                        |
| `fileFilter(name == "dub.sdl")`        | files with exactly that name; a directory so named selects nothing  |
| `fileFilter(type == "symlink")`        | symbolic links (or `"regular"`)                                     |
| `fileFilter(p && q)`, `p \|\| q`, `!p` | predicates combined                                                 |
| `# …`                                  | a comment, to the end of the line                                   |

A query may span lines. Operators must stand apart from globs: `a-b.d` is one
glob, `a - b.d` a difference. A `#` starts a comment only where a token could
start, so `a#b` is a glob.

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

A glob without a `/` before its last character matches at any depth:

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

A union adds what another glob selects:

::: try fileset {tree=tutorial}

```fileset
*.md | dub.sdl
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
src/** & *_test.d
```

```tree
src/
└─ lib_test.d
```

:::

`exec` holds the executable files:

::: try fileset {tree=tutorial}

```fileset
exec
```

```tree
bin/
└─ run
```

:::

`fileFilter` decides each file by its own name, as Nix's does:

::: try fileset {tree=tutorial}

```fileset
fileFilter(hasExt("d") && !name == "app.d")
```

```tree
src/
├─ lib.d
├─ lib_test.d
└─ util/
   └─ strings.d
```

:::

Everything but the build's outputs, as a source archive holds it:

::: try fileset {tree=tutorial}

```fileset
all - build/** - bin/**
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
gitTracked & **/*.md
```

:::

## Export

The Export tab writes the query for another system, or says why that system
cannot express it. A translation is never approximate: the files it selects are
exactly the members, checked against each system's own tool.

| Target         | Accepts                                                                      |
| -------------- | ---------------------------------------------------------------------------- |
| `nix`          | everything but `exec` and the case-insensitive policy; globs by a shim       |
| `git-pathspec` | a union of globs minus a union of globs, with `gitTracked`                   |
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
