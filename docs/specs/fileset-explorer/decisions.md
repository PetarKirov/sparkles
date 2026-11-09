---
status: draft
owner: fileset-explorer
reviewed: 2026-11-09
---

# Fileset explorer — Decisions

Each record states its question, the alternatives, the choice and when to
revisit it. All were made by the owner on 2026-11-09, in the review that
followed the first, single-file example.

## X1: An application, with its parts in libraries

**Question.** The explorer started as `libs/build-primitives/examples/fileset-explorer.d`.
A grammar, a help system and code generators do not fit in one file, and a
single-file example builds no tests.

**Alternatives.** A new application; a `hue` subcommand, reusing hue's markdown
preview and configuration; an example that only wires library code.

**Choice.** `apps/fileset-explorer`, with its own tests. What other tools can
use goes to libraries: the query language and the generators to
`sparkles:build-primitives`, the try block to `sparkles:syntax` and
`sparkles:source-view`, the file-type icons to `sparkles:ui`. The example is
removed.

**Revisit** if hue wants the explorer as a pane: the application is then a
component hue embeds.

## X2: The caret is the host's text cursor

**Question.** The editor view draws the caret as a `▏` character inserted into
the line, so the text after it moves as the caret does.

**Alternatives.** A host errand that places the terminal's own cursor; a caret
painted over the cell instead of inserted; both.

**Choice.** The host errand, `HST20`, which every `EditorField` gets: the
terminal shows its own cursor, blinking as the user configured it, and the GPU
host draws a bar. The editor view gains an option that inserts nothing and
reports the caret's position instead.

## X3: `#` comments, where a token could begin

**Question.** Which syntax ends a query at the end of a line?

**Alternatives.** `#` where a token could begin, as bash; `//`, which no glob
contains but is foreign to Nix and shell users; `--`, which collides with `-`.

**Choice.** `#` as bash reads it, which is also Nix's and `.gitignore`'s. A
name beginning with `#`, such as Emacs's `#foo#`, is written as a string.

## X4: Double-quoted strings

**Choice.** `"…"` is one glob, with `\"` and `\\` escapes, as Nix writes
strings, so a string copies into Nix unchanged. Single quotes and
backslash-only escaping were rejected: the first cannot hold a quote, the
second makes `\` mean two things in a glob.

## X5: Nix's function names, in call syntax

**Question.** Keep only the infix operators, add function forms, or parse a
subset of Nix?

**Choice.** Both: infix for typing, and `unions(…)`, `intersection(…)`,
`difference(…)`, `fileFilter(…)` with Nix's names in call syntax, so a Nix
user's vocabulary works and Nix output is a near copy. A Nix subset was
rejected: lambdas and attribute access are a language to implement for no
selection they add.

## X6: The grammar lives in this repository

**Alternatives.** Its own repository pinned as a flake input, as
`tree-sitter-sdl` is; this repository; no grammar, highlighting from the D
parser's tokens.

**Choice.** `nix/packages/tree-sitter-fileset/`, `grammar.js` and the generated
`src/parser.c` committed, built into the `ts-grammars` bundle. `FXL8` keeps it
equal to the parser. The docs site keeps Shiki until the planned tree-sitter
renderer replaces it.

## X7: Exact or refused, each target to its maximum

**Question.** A target that cannot express a query: approximate, refuse, or
fall back to a list of paths? And is the accepted set one shared normal form
or each target's own?

**Choice.** Refuse, naming the construct and its span (invariant 2). Each
target accepts as much as it expresses exactly, after the shared rewrites of
`FXE2`: `rsync` and `gitignore` take decision lists, `git-pathspec`, `bazel`
and `dub` an include set minus an exclude set, `tar` literal includes, `cargo`
a union. Each has its own oracle.

## X8: Nix globs through a shim

**Question.** `lib.fileset` has no globs: it has paths and `fileFilter` over a
file's name, type and extension. How does a glob reach Nix?

**Alternatives.** Refuse globs beyond paths and name patterns; expand a glob to
the paths it matches now; emit a function that implements the glob at
evaluation time, as `nix/packages/example-catalogue.nix` walks a tree with
`builtins.readDir`.

**Choice.** All three, as a mode chosen in the Export tab, the shim by default.
The shim is written inline in a `let`, so the code a user copies is what the
oracle evaluates and needs no input but `lib`. Expanded paths are marked as a
snapshot. With the shim, `gitignored` is the root minus `gitTracked` only where
that is exact (a work tree with nothing untracked); `exec` is refused, since
`builtins.readDir` does not report the executable bit.

## X9: The try block is a container; runners return widgets

**Question.** How does a page mark a block runnable, for the fileset runner now
and others (a D snippet run through run.dlang.org) later?

**Alternatives.** A `::: try <runner>` container; a meta word in the fence's
info string (as `twoslash`); an HTML comment directive (as
`md-example-expected`); `@mdit/plugin-attrs` attributes on the fence.

**Choice.** The container, which pairs the input with its expected result and
renders as a card on the docs site. A runner returns a widget tree; CI compares
an expected result with that tree rendered as text, so no second, textual
result is needed. A text result may be added when a runner needs it.

## X10: The tutorial's tree is in the page

**Choice.** A ` ```tree-literal {#name} ` fence in the help page declares
the tree its try blocks run on, in memory. Readers see the tree the prose
describes; the user may still run a block on the open directory.

## X11: Help is a tab beside the stats

**Question.** Where does help appear without hiding the tree, on a terminal of
any width?

**Alternatives.** Replacing the tree; a modal; a third column.

**Choice.** The right column of the dock is a tabbed group, Stats, Help and
Export; F1 activates Help. A try block's result is visible in the tree beside
it, and a wide terminal can split the group.

## X12: `gitTracked` throws outside a work tree

**Choice.** As `lib.fileset.gitTracked` does: the query fails to resolve, and
the error is shown like a parse error. An empty set was rejected, because a
mistyped `--dir` would silently select nothing.

## X13: One file-type icon table

**Choice.** hue's explorer table (`XPL6`) moves to `sparkles:ui` and both
applications use it, so a file looks the same in both.

The records below were made during delivery, from what the oracles showed;
each keeps to the decisions above.

## X14: `fileFilter` gets leaves of its own

**Question.** `fileFilter(name == "x")` is the files named `x`. A glob `x` is
also every file beneath a directory named `x`, `x/x` included, and no
difference of globs takes that back exactly.

**Choice.** The fileset library gains two leaves, `fileName(p)` and
`symlinks()` (filesets `FSV7`), with `paths(list)` for `gitTracked`
(`FSV6`). A predicate lowers to them, so `fileFilter` means what Nix's means,
and the generators can tell it from a glob: Bazel and rsync, which match a
file's own name, take it; git pathspecs, Cargo and tar, which would take a
directory's contents too, refuse it.

## X15: dub gets the members

**Question.** Which of a query's forms can dub's `sourceFiles` and
`excludedSourceFiles` express?

**Evidence.** dub's oracle answered none: a `sourceFiles` glob lists the
directories it matches as source files, and an `excludedSourceFiles` glob such
as `**_test.d` excluded nothing.

**Choice.** The `dub` target writes the members out, a snapshot as Nix's
`expand` mode is, and refuses a member dub would hand the linker, such as a
`.o`, which its source list leaves out. Exactness on every tree is out of
reach for dub until its globs behave as globs.

**Revisit** when dub's glob handling changes; the oracle will show it.
